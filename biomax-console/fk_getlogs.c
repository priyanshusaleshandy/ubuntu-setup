#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

/* Reads attendance logs directly from a BioMax/FK623 device via FK623Attend.dll,
 * bypassing SmartOffice entirely. Signature confirmed against the official
 * FKAttend User's Manual (section 3.3.5/3.3.9):
 *   FK_LoadGeneralLogData(nHandleIndex, nReadMark)  - nReadMark: 0=all records, 1=new-only
 *   FK_GetGeneralLogData_1(nHandleIndex, *enrollNumber, *verifyMode, *inOutMode,
 *                          *year, *month, *day, *hour, *minute, *sec)
 * Note: this device firmware does NOT support the StringID variant for logs
 * (FK_GetLogDataIsSupportStringID returns 0 even though user StringID support is 1),
 * so enrollNumber comes back as a plain numeric long, not a string. */

typedef int (__stdcall *FK_ConnectNet_t)(int, const char*, int, int, int, int, int);
typedef int (__stdcall *FK_DisConnect_t)(int);
typedef int (__stdcall *FK_LoadGeneralLogData_t)(int, int);
typedef int (__stdcall *FK_GetGeneralLogData_1_t)(int, int*, int*, int*, int*, int*, int*, int*, int*, int*);

int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: fk_getlogs <ip> [readmark:0|1]\n"); return 1; }
    const char* ip = argv[1];
    int readMark = (argc >= 3) ? atoi(argv[2]) : 0;  /* default: read everything */

    HMODULE dll = LoadLibraryA("FK623Attend.dll");
    if (!dll) { printf("LOADFAIL\n"); return 1; }

    FK_ConnectNet_t FK_ConnectNet = (FK_ConnectNet_t)GetProcAddress(dll, "FK_ConnectNet");
    FK_DisConnect_t FK_DisConnect = (FK_DisConnect_t)GetProcAddress(dll, "FK_DisConnect");
    FK_LoadGeneralLogData_t FK_LoadGeneralLogData = (FK_LoadGeneralLogData_t)GetProcAddress(dll, "FK_LoadGeneralLogData");
    FK_GetGeneralLogData_1_t FK_GetGeneralLogData_1 = (FK_GetGeneralLogData_1_t)GetProcAddress(dll, "FK_GetGeneralLogData_1");

    if (!FK_ConnectNet || !FK_DisConnect || !FK_LoadGeneralLogData || !FK_GetGeneralLogData_1) {
        printf("MISSING_EXPORT\n");
        return 1;
    }

    int handle = FK_ConnectNet(1, ip, 5005, 5000, 0, 0, 1261);
    printf("CONNECT %d\n", handle);
    if (handle != 1) { return 1; }

    int loaded = FK_LoadGeneralLogData(handle, readMark);
    printf("LOAD %d\n", loaded);
    if (loaded != 1) {
        FK_DisConnect(handle);
        return 1;
    }

    int count = 0;
    while (count < 50000) {
        int enrollNumber = -1, verifyMode = -1, inOutMode = -1;
        int year = -1, month = -1, day = -1, hour = -1, minute = -1, second = -1;
        int r = FK_GetGeneralLogData_1(handle, &enrollNumber, &verifyMode, &inOutMode,
                                        &year, &month, &day, &hour, &minute, &second);
        if (r != 1) { printf("ITER_END %d\n", r); break; }
        printf("LOG|%d|%d|%d|%04d-%02d-%02d %02d:%02d:%02d\n",
               enrollNumber, verifyMode, inOutMode, year, month, day, hour, minute, second);
        count++;
    }
    printf("TOTAL %d\n", count);

    FK_DisConnect(handle);
    return 0;
}
