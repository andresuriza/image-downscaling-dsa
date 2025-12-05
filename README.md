# Proyecto 2 - Arquitectura de Computadores II

## Acelerador de Downscaling de Imágenes para DE1-SoC

---

## Requisitos del Sistema

### Hardware
- Placa DE1-SoC (Terasic)
- Cable USB-Blaster para programación JTAG

### Software
- Intel Quartus Prime 20.1 Lite Edition
- MinGW/GCC para Windows

---

## 1. Compilación del Software

```powershell
cd src\sw\console
make all
```

Esto genera `dsa_console.exe` y las herramientas de validación.

---

## 2. Síntesis del Hardware (Quartus GUI)

1. Abrir **Quartus Prime**
2. **File → Open Project** → seleccionar `DE1_SOC.qpf`
3. **Processing → Start Compilation**
4. Esperar a que termine la compilación

Al finalizar se genera el archivo `DE1_SOC.sof`.

---

## 3. Programación de la FPGA

1. Conectar la placa DE1-SoC vía USB-Blaster y encenderla
2. En Quartus: **Tools → Programmer**
3. **Hardware Setup** → seleccionar **USB-Blaster**
4. **Add File** → seleccionar `DE1_SOC.sof`
5. Marcar **Program/Configure**
6. Click en **Start**

---

## 4. Ejecución del Sistema

```powershell
cd src\sw\console
.\dsa_console.exe
```

### Comandos de la Consola

| Comando | Descripción |
|---------|-------------|
| `connect` | Conectar a la FPGA vía JTAG |
| `disconnect` | Cerrar conexión JTAG |
| `set scale <f>` | Factor de escala (0.50, 0.55, ... 0.95, 1.00) |
| `set mode <serial\|simd>` | Modo de procesamiento (simd=4 lanes) |
| `run` | Iniciar procesamiento (continuo) |
| `step` | Ejecutar un paso (debug) |
| `continue` | Continuar (desactivar modo stepping) |
| `reset` | Reiniciar acelerador |
| `load <file.pgm>` | Cargar imagen de entrada |
| `verify` | Verificar imagen en SDRAM |
| `dump <file.pgm>` | Guardar imagen de salida |
| `compare [ref.pgm]` | Comparar salida con modelo de referencia C |
| `show config` | Mostrar configuración |
| `show perf` | Mostrar contadores de rendimiento |
| `show debug` | Mostrar info de debug (FSM, coords, pixels) |
| `show all` | Mostrar todo |
| `read <addr>` | Leer CSR en offset (hex) |
| `write <addr> <val>` | Escribir CSR (hex) |
| `mem <addr> [count]` | Leer bytes de memoria (hex dump) |
| `verbose <0\|1>` | Activar/desactivar modo verbose |
| `help` | Mostrar ayuda |
| `quit` | Salir de la consola |

---

## 5. Generación de Imágenes de Prueba

```bash
cd test/scripts
python3 generate_tests_from_c.py
```

Esto genera imágenes de prueba en el directorio `test_images/`.

---

## 6. Validación de Referencias

```bash
make validate_c_ref
```

Esto valida la interpolación bilineal en Python y SystemVerilog contra el modelo de referencia en C.

---

## 7. Ejecución de Pruebas Unitarias

```bash
make test_units
```

Esto ejecuta las pruebas unitarias para los módulos SIMD y Serial.

---

## 8. Pruebas de Integración

```bash
make sim_top
```

Esto ejecuta pruebas de integración para el sistema completo.

---

## 9. Comparación de Implementaciones

```bash
make sim_compare
```

Esto compara las salidas de las implementaciones SIMD y Serial.

---

## 10. Ejecución de Todas las Pruebas

```bash
make test_all
```

Esto ejecuta todas las pruebas en secuencia: validación, unitarias, integración y comparación.

---

## 11. Limpieza

```bash
make clean
```

Esto elimina archivos generados y artefactos de simulación.
