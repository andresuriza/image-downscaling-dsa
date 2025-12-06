/*
 * Comunicación JTAG - Modo Persistente
 * 
 * Mantiene system-console corriendo como subproceso y comunica vía pipes.
 * Evita el overhead de inicio de JVM (2-3 segundos) en cada comando.
 * Optimizado para Windows (WriteFile/ReadFile) y Linux (read/write).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#endif

#include "jtag_comm.h"

/* Estado del subproceso system-console persistente */
typedef struct {
#ifdef _WIN32
    HANDLE hProcess;      // Handle del proceso system-console
    HANDLE hStdinWrite;   // Pipe de escritura (envía comandos)
    HANDLE hStdoutRead;   // Pipe de lectura (recibe respuestas)
#else
    pid_t pid;            // PID del proceso hijo
    int stdin_fd;         // File descriptor de stdin del hijo
    int stdout_fd;        // File descriptor de stdout del hijo
#endif
    bool active;          // Si el proceso está corriendo
} jtag_process_t;

static jtag_process_t g_proc = {0};

/* Mensajes de error legibles para cada código JTAG_ERR_* */
static const char* error_messages[] = {
    "OK",
    "Failed to open JTAG connection",
    "Write operation failed", 
    "Read operation failed",
    "Operation timed out",
    "JTAG not connected"
};

const char* jtag_strerror(int err) {
    if (err >= 0) return error_messages[0];
    int idx = -err;
    if (idx < (int)(sizeof(error_messages)/sizeof(error_messages[0]))) {
        return error_messages[idx];
    }
    return "Unknown error";
}

void jtag_set_verbose(jtag_ctx_t *ctx, int level) {
    if (ctx) ctx->verbose = level;
}

#ifdef _WIN32

/* Escribir comando al pipe de stdin de system-console (Windows) */
static int write_to_pipe(const char *data) {
    if (!g_proc.active) return JTAG_ERR_NOT_OPEN;
    
    DWORD written;
    DWORD len = (DWORD)strlen(data);
    if (!WriteFile(g_proc.hStdinWrite, data, len, &written, NULL)) {
        return JTAG_ERR_WRITE;
    }
    FlushFileBuffers(g_proc.hStdinWrite);  // Forzar envío inmediato
    return JTAG_OK;
}

/* Leer respuesta del pipe de stdout de system-console (Windows)
 * Acumula datos hasta encontrar prompt '% ' o alcanzar timeout
 * timeout_ms: tiempo máximo de espera (-1 = infinito)
 */
static int read_from_pipe(char *buffer, size_t buf_size, int timeout_ms) {
    if (!g_proc.active) return JTAG_ERR_NOT_OPEN;
    
    size_t total = 0;
    DWORD bytes_read;
    DWORD start = GetTickCount();
    
    buffer[0] = '\0';
    
    while (total < buf_size - 1) {
        /* Verificar timeout */
        if (timeout_ms > 0 && (GetTickCount() - start) > (DWORD)timeout_ms) {
            return JTAG_ERR_TIMEOUT;
        }
        
        /* Check if data available */
        DWORD available = 0;
        if (!PeekNamedPipe(g_proc.hStdoutRead, NULL, 0, NULL, &available, NULL)) {
            break;
        }
        
        if (available == 0) {
            Sleep(10);
            continue;
        }
        
        /* Read one byte at a time to detect end marker */
        char c;
        if (!ReadFile(g_proc.hStdoutRead, &c, 1, &bytes_read, NULL) || bytes_read == 0) {
            break;
        }
        
        buffer[total++] = c;
        buffer[total] = '\0';
        
        /* Check for end marker "###END###" */
        if (total >= 9) {
            char *end = strstr(buffer, "###END###");
            if (end) {
                *end = '\0';  /* Remove marker */
                /* Trim trailing whitespace */
                while (end > buffer && (*(end-1) == '\n' || *(end-1) == '\r')) {
                    *(--end) = '\0';
                }
                break;
            }
        }
    }
    
    return JTAG_OK;
}

/* Arrancar proceso system-console con pipes redirigidos (Windows)
 * Pasos:
 * 1. Crear pipes stdin/stdout con herencia habilitada
 * 2. Construir ruta absoluta a jtag_server.tcl (en directorio del .exe)
 * 3. Crear proceso con CreateProcess (sin ventana)
 * 4. Guardar handles en g_proc para comunicación posterior
 */
static int start_server_process(jtag_ctx_t *ctx) {
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = NULL;

    HANDLE hStdinRead, hStdinWrite;
    HANDLE hStdoutRead, hStdoutWrite;

    /* Crear pipes para stdin (consola escribe comandos) */
    if (!CreatePipe(&hStdinRead, &hStdinWrite, &sa, 0)) {
        return JTAG_ERR_OPEN;
    }
    SetHandleInformation(hStdinWrite, HANDLE_FLAG_INHERIT, 0);

    /* Crear pipe para stdout (consola lee respuestas) */
    if (!CreatePipe(&hStdoutRead, &hStdoutWrite, &sa, 0)) {
        CloseHandle(hStdinRead);
        CloseHandle(hStdinWrite);
        return JTAG_ERR_OPEN;
    }
    SetHandleInformation(hStdoutRead, HANDLE_FLAG_INHERIT, 0);

    /* Obtener ruta a jtag_server.tcl (mismo directorio que dsa_console.exe) */
    char exe_path[MAX_PATH];
    char tcl_path[MAX_PATH + 32];
    GetModuleFileNameA(NULL, exe_path, sizeof(exe_path));
    char *last_slash = strrchr(exe_path, '\\');
    if (last_slash) {
        *last_slash = '\0';
        snprintf(tcl_path, sizeof(tcl_path), "%s\\jtag_server.tcl", exe_path);
    } else {
        strcpy(tcl_path, "jtag_server.tcl");
    }

    /* Construir línea de comando: system-console.exe --script=jtag_server.tcl */
    char cmd[MAX_PATH * 3];
    snprintf(cmd, sizeof(cmd), 
             "\"%s\\sopc_builder\\bin\\system-console.exe\" --script=\"%s\"",
             ctx->quartus_path, tcl_path);

    if (ctx->verbose) {
        printf("[JTAG] Starting: %s\n", cmd);
    }

    /* Configurar STARTUPINFO para redirigir stdin/stdout del proceso hijo */
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.hStdInput = hStdinRead;
    si.hStdOutput = hStdoutWrite;
    si.hStdError = hStdoutWrite;
    si.dwFlags |= STARTF_USESTDHANDLES;

    ZeroMemory(&pi, sizeof(pi));

    /* Crear proceso sin ventana, heredando handles de pipes */
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 
                        CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(hStdinRead);
        CloseHandle(hStdinWrite);
        CloseHandle(hStdoutRead);
        CloseHandle(hStdoutWrite);
        return JTAG_ERR_OPEN;
    }

    /* Cerrar handles que el padre no necesita (el hijo los heredó) */
    CloseHandle(hStdinRead);
    CloseHandle(hStdoutWrite);
    CloseHandle(pi.hThread);

    /* Guardar handles de comunicación en estructura global */
    g_proc.hProcess = pi.hProcess;
    g_proc.hStdinWrite = hStdinWrite;
    g_proc.hStdoutRead = hStdoutRead;
    g_proc.active = true;

    return JTAG_OK;
}

/* Detener proceso system-console (Windows)
 * 1. Enviar comando QUIT (cierre graceful)
 * 2. Esperar 1s para que termine
 * 3. Forzar terminación si aún está activo
 * 4. Liberar todos los handles
 */
static void stop_server_process(void) {
    if (!g_proc.active) return;

    /* Enviar comando QUIT para cierre graceful */
    write_to_pipe("QUIT\n");
    
    /* Esperar brevemente que el proceso termine */
    WaitForSingleObject(g_proc.hProcess, 1000);
    TerminateProcess(g_proc.hProcess, 0);

    CloseHandle(g_proc.hStdinWrite);
    CloseHandle(g_proc.hStdoutRead);
    CloseHandle(g_proc.hProcess);

    g_proc.active = false;
}

#else
/* Implementación Linux/Unix (placeholder - no implementado) */
static int write_to_pipe(const char *data) { (void)data; return JTAG_ERR_NOT_OPEN; }
static int read_from_pipe(char *buffer, size_t buf_size, int timeout_ms) { 
    (void)buffer; (void)buf_size; (void)timeout_ms; return JTAG_ERR_NOT_OPEN; 
}
static int start_server_process(jtag_ctx_t *ctx) { (void)ctx; return JTAG_ERR_OPEN; }
static void stop_server_process(void) {}
#endif

/*===========================================================================
 * Ejecución de Comandos JTAG
 *===========================================================================*/

/* Enviar comando al servidor TCL y leer respuesta
 * Timeout: 10s para comandos normales
 * Verifica si la respuesta empieza con ERROR
 */
static int send_command(jtag_ctx_t *ctx, const char *cmd, char *response, size_t resp_size) {
    if (!g_proc.active) return JTAG_ERR_NOT_OPEN;
    
    if (ctx->verbose) {
        printf("[JTAG] >> %s", cmd);
    }
    
    int ret = write_to_pipe(cmd);
    if (ret != JTAG_OK) return ret;
    
    ret = read_from_pipe(response, resp_size, 10000);  /* 10 second timeout */
    if (ret != JTAG_OK) return ret;
    
    if (ctx->verbose) {
        printf("[JTAG] << %s\n", response);
    }
    
    /* Verificar si la respuesta indica error */
    if (strncmp(response, "ERROR", 5) == 0) {
        return JTAG_ERR_READ;
    }
    
    return JTAG_OK;
}

/*===========================================================================
 * API Pública JTAG
 *===========================================================================*/

/* Abrir conexión JTAG:
 * 1. Aplicar defaults de rutas si no están configuradas
 * 2. Arrancar proceso system-console persistente
 * 3. Esperar mensaje de conexión (timeout 20s para inicio de JVM)
 * 4. Verificar JTAG_OK en respuesta (ignora banner de system-console)
 */
int jtag_open(jtag_ctx_t *ctx) {
    if (!ctx) return JTAG_ERR_OPEN;

    /* Aplicar defaults si no están especificados */
    if (ctx->quartus_path[0] == '\0') {
        strncpy(ctx->quartus_path, QUARTUS_PATH, sizeof(ctx->quartus_path) - 1);
    }
    if (ctx->master_path[0] == '\0') {
        strncpy(ctx->master_path, DEFAULT_MASTER_PATH, sizeof(ctx->master_path) - 1);
    }

    /* Arrancar proceso persistente (system-console + jtag_server.tcl) */
    int ret = start_server_process(ctx);
    if (ret != JTAG_OK) {
        return ret;
    }

    /* Leer mensaje de conexión (saltar banner de system-console, buscar JTAG_OK) */
    char response[4096];
    ret = read_from_pipe(response, sizeof(response), 20000);  /* 20s for JVM startup */
    if (ret != JTAG_OK) {
        stop_server_process();
        return ret;
    }

    /* Buscar JTAG_OK en respuesta (ignorar banner de system-console) */
    char *ok_msg = strstr(response, "JTAG_OK");
    if (ctx->verbose && ok_msg) {
        printf("[JTAG] Server: %s\n", ok_msg);
    }

    /* Verificar que la conexión fue exitosa */
    if (ok_msg == NULL) {
        if (ctx->verbose) {
            printf("[JTAG] Response: %s\n", response);
        }
        stop_server_process();
        return JTAG_ERR_OPEN;
    }

    ctx->connected = true;
    return JTAG_OK;
}

void jtag_close(jtag_ctx_t *ctx) {
    if (!ctx) return;
    stop_server_process();
    ctx->connected = false;
}

bool jtag_is_connected(jtag_ctx_t *ctx) {
    return ctx && ctx->connected && g_proc.active;
}

int jtag_read_32(jtag_ctx_t *ctx, uint32_t addr, uint32_t *value) {
    if (!ctx || !value) return JTAG_ERR_NOT_OPEN;

    char cmd[64];
    char response[256];
    
    snprintf(cmd, sizeof(cmd), "READ32 0x%08X\n", addr);
    
    int ret = send_command(ctx, cmd, response, sizeof(response));
    if (ret != JTAG_OK) return ret;
    
    *value = strtoul(response, NULL, 0);
    return JTAG_OK;
}

int jtag_write_32(jtag_ctx_t *ctx, uint32_t addr, uint32_t value) {
    if (!ctx) return JTAG_ERR_NOT_OPEN;

    char cmd[64];
    char response[256];
    
    snprintf(cmd, sizeof(cmd), "WRITE32 0x%08X 0x%08X\n", addr, value);
    
    return send_command(ctx, cmd, response, sizeof(response));
}

/* Máximo de bytes por comando READMEM - limitar tamaño de buffer de respuesta */
#define READ_CHUNK_SIZE 256

/* Leer bloque de memoria en chunks:
 * - Divide transferencia en bloques de 256 bytes
 * - Parsea respuesta con bytes en hexadecimal separados por espacios
 * - Muestra progreso cada 4KB en transferencias grandes
 */
int jtag_read_block(jtag_ctx_t *ctx, uint32_t addr, uint8_t *data, size_t len) {
    if (!ctx || !data) return JTAG_ERR_NOT_OPEN;

    char cmd[64];
    char response[READ_CHUNK_SIZE * 5 + 256];  /* Buffer para bytes hex + overhead */
    size_t offset = 0;
    
    while (offset < len) {
        size_t chunk = (len - offset > READ_CHUNK_SIZE) ? READ_CHUNK_SIZE : (len - offset);
        
        snprintf(cmd, sizeof(cmd), "READMEM 0x%08X %zu\n", addr + (uint32_t)offset, chunk);
        
        int ret = send_command(ctx, cmd, response, sizeof(response));
        if (ret != JTAG_OK) return ret;
        
        /* Parsear bytes hexadecimales separados por espacios */
        char *tok = strtok(response, " \t\n\r");
        size_t i = 0;
        while (tok && i < chunk) {
            data[offset + i] = (uint8_t)strtoul(tok, NULL, 0);
            i++;
            tok = strtok(NULL, " \t\n\r");
        }
        
        if (i < chunk) {
            /* Error: no se recibieron todos los bytes esperados */
            return JTAG_ERR_READ;
        }
        
        offset += chunk;
        
        /* Progress indicator for large transfers */
        if (len > 1024 && (offset % 4096) == 0) {
            printf("\r  Progress: %zu / %zu bytes (%.1f%%)", offset, len, 100.0 * offset / len);
            fflush(stdout);
        }
    }
    
    if (len > 1024) {
        printf("\r  Progress: %zu / %zu bytes (100.0%%)\n", len, len);
    }

    return JTAG_OK;
}

/* Máximo de bytes por comando WRITEMEM - mantener razonable para parsing TCL */
#define WRITE_CHUNK_SIZE 256

/* Escribir bloque de memoria en chunks:
 * - Divide transferencia en bloques de 256 bytes
 * - Construye comando dinámico con lista de bytes en hex
 * - Libera memoria del comando después de cada chunk
 * - Muestra progreso cada 4KB
 */
int jtag_write_block(jtag_ctx_t *ctx, uint32_t addr, const uint8_t *data, size_t len) {
    if (!ctx || !data) return JTAG_ERR_NOT_OPEN;

    char response[256];
    size_t offset = 0;
    
    /* Procesar en chunks de 256 bytes */
    while (offset < len) {
        size_t chunk = (len - offset > WRITE_CHUNK_SIZE) ? WRITE_CHUNK_SIZE : (len - offset);
        
        /* Construir comando dinámico: WRITEMEM addr 0x00 0x01 ... */
        char *cmd = malloc(chunk * 5 + 64);
        if (!cmd) return JTAG_ERR_WRITE;
        
        int pos = sprintf(cmd, "WRITEMEM 0x%08X", addr + (uint32_t)offset);
        
        for (size_t i = 0; i < chunk; i++) {
            pos += sprintf(cmd + pos, " 0x%02X", data[offset + i]);
        }
        strcat(cmd, "\n");
        
        int ret = send_command(ctx, cmd, response, sizeof(response));
        free(cmd);
        
        if (ret != JTAG_OK) {
            return ret;
        }
        
        offset += chunk;
        
        /* Progress indicator for large transfers */
        if (len > 1024 && (offset % 4096) == 0) {
            printf("\r  Progress: %zu / %zu bytes (%.1f%%)", offset, len, 100.0 * offset / len);
            fflush(stdout);
        }
    }
    
    if (len > 1024) {
        printf("\r  Progress: %zu / %zu bytes (100.0%%)\n", len, len);
    }
    
    return JTAG_OK;
}

