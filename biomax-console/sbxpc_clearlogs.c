#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <oleauto.h>

/* DESTRUCTIVE: wipes the attendance log memory of device 604 (EBKN A30C) via
 * _EmptyGeneralLogData. Only run this once the logs are confirmed stored in
 * biomax.db - the device keeps no second copy.
 *
 * Why it exists: the device's push channel only trickles one backlog record per
 * ~66s, so with ~81k records queued a punch made today would not reach the
 * listener for about two months. Emptying the log memory drains that queue so
 * live punches arrive within seconds.
 *
 * Requires the literal argument I-HAVE-A-BACKUP so it cannot fire by accident or
 * from a mistyped command. Reports the log count before and after so the caller
 * can see what it actually did.
 *
 * This only touches attendance logs. Enrolled users and fingerprints live in a
 * different store and are untouched - _EmptyEnrollData is never referenced. */

typedef unsigned char u8;
typedef u8 (__stdcall *ConnectTcpip_t)(int, BSTR *, int, int);
typedef void (__stdcall *Disconnect_t)(int);
typedef u8 (__stdcall *GetLastError_t)(int, int *);
typedef u8 (__stdcall *EnableDevice_t)(int, u8);
typedef u8 (__stdcall *GetDeviceStatus_t)(int, int, unsigned int *);
typedef u8 (__stdcall *EmptyGeneralLogData_t)(int);

#define STATUS_GLOG_COUNT 6

static BSTR bstr_from_ascii(const char *s) {
    int n = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
    WCHAR *w = (WCHAR *)malloc(n * sizeof(WCHAR));
    MultiByteToWideChar(CP_ACP, 0, s, -1, w, n);
    BSTR b = SysAllocString(w);
    free(w);
    return b;
}

int main(int argc, char **argv) {
    if (argc < 3 || strcmp(argv[2], "I-HAVE-A-BACKUP") != 0) {
        printf("usage: sbxpc_clearlogs <ip> I-HAVE-A-BACKUP\n");
        printf("refusing to run without the confirmation argument\n");
        return 1;
    }
    const char *ip = argv[1];

    HMODULE dll = LoadLibraryA("SBXPCDLL.dll");
    if (!dll) { printf("LOADFAIL %lu\n", (unsigned long)GetLastError()); return 1; }

    ConnectTcpip_t ConnectTcpip = (ConnectTcpip_t)GetProcAddress(dll, "_ConnectTcpip");
    Disconnect_t Disconnect = (Disconnect_t)GetProcAddress(dll, "_Disconnect");
    GetLastError_t SbGetLastError = (GetLastError_t)GetProcAddress(dll, "_GetLastError");
    EnableDevice_t EnableDevice = (EnableDevice_t)GetProcAddress(dll, "_EnableDevice");
    GetDeviceStatus_t GetDeviceStatus = (GetDeviceStatus_t)GetProcAddress(dll, "_GetDeviceStatus");
    EmptyGeneralLogData_t EmptyGeneralLogData =
        (EmptyGeneralLogData_t)GetProcAddress(dll, "_EmptyGeneralLogData");

    if (!ConnectTcpip || !Disconnect || !EnableDevice || !GetDeviceStatus || !EmptyGeneralLogData) {
        printf("MISSING_EXPORT\n");
        return 1;
    }

    BSTR bip = bstr_from_ascii(ip);
    u8 ok = ConnectTcpip(1, &bip, 5005, 0);
    SysFreeString(bip);
    printf("CONNECT %d\n", (int)ok);
    fflush(stdout);
    if (!ok) return 2;

    printf("DISABLE %d\n", (int)EnableDevice(1, 0));
    fflush(stdout);

    unsigned int before = 0, after = 0;
    GetDeviceStatus(1, STATUS_GLOG_COUNT, &before);
    printf("GLOG_BEFORE %u\n", before);
    fflush(stdout);

    u8 r = EmptyGeneralLogData(1);
    printf("EMPTY %d\n", (int)r);
    fflush(stdout);
    if (!r && SbGetLastError) {
        int err = -1;
        SbGetLastError(1, &err);
        printf("LASTERROR %d\n", err);
    }

    GetDeviceStatus(1, STATUS_GLOG_COUNT, &after);
    printf("GLOG_AFTER %u\n", after);

    EnableDevice(1, 1);
    Disconnect(1);
    return r ? 0 : 3;
}
