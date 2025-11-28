@echo off
REM Build script for DSA Console
REM Requires MSYS2 (GCC), Visual Studio Build Tools, or MinGW

echo === DSA Console Build Script ===

REM Try MSYS2 first (most common on Windows)
if exist "C:\msys64\ucrt64\bin\gcc.exe" (
    echo Using MSYS2 GCC...
    C:\msys64\ucrt64\bin\gcc.exe -Wall -O2 dsa_console.c jtag_comm.c -o dsa_console.exe
    goto :done
)

REM Try MinGW in PATH
where gcc >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo Using GCC...
    gcc -Wall -O2 dsa_console.c jtag_comm.c -o dsa_console.exe
    goto :done
)

REM Try LLVM/Clang
where clang >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo Using Clang...
    clang -Wall -O2 dsa_console.c jtag_comm.c -o dsa_console.exe
    goto :done
)

echo ERROR: No C compiler found!
echo.
echo Please install one of:
echo   1. MSYS2: https://www.msys2.org/
echo      Then run: pacman -S mingw-w64-ucrt-x86_64-gcc
echo   2. MinGW-w64: https://www.mingw-w64.org/downloads/
echo.
exit /b 1

:done
if exist dsa_console.exe (
    echo.
    echo Build successful: dsa_console.exe
    echo Run with: dsa_console.exe
) else (
    echo Build failed!
    exit /b 1
)
