#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <oleauto.h>

/* Bulk-pull attendance logs off device 604 (EBKN A30C) via SBXPCDLL.dll.
 *
 * The push channel only trickles one backlog record per ~66s, so with ~81k
 * records on the device it is useless for history - this pulls them directly.
 *
 *   byte _ReadAllGLogData(int machineNo)                  fetch every record
 *   bool _ReadGLogWithPos(int machineNo, int start, int end)   fetch a window
 *   byte _GetAllGLogData(int machineNo, int* tMachineNo, int* enrollNo,
 *                        int* eMachineNo, int* verifyMode,
 *                        int* y, int* mo, int* d, int* h, int* mi, int* s)
 *
 * Note there is no in/out direction field in this SDK's log record, unlike the
 * FK623 one - the device only reports it in its push XML (<AttendStat>).
 *
 * Read-only. _EmptyGeneralLogData (wipe the device's log buffer) is deliberately
 * never referenced here. */

typedef unsigned char u8;
typedef u8 (__stdcall *ConnectTcpip_t)(int, BSTR *, int, int);
typedef void (__stdcall *Disconnect_t)(int);
typedef u8 (__stdcall *GetLastError_t)(int, int *);
typedef u8 (__stdcall *EnableDevice_t)(int, u8);
typedef u8 (__stdcall *ReadAllGLogData_t)(int);
typedef int (__stdcall *ReadGLogWithPos_t)(int, int, int);
typedef u8 (__stdcall *GetAllGLogData_t)(int, int *, int *, int *, int *,
                                         int *, int *, int *, int *, int *, int *);

static BSTR bstr_from_ascii(const char *s) {
    int n = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
    WCHAR *w = (WCHAR *)malloc(n * sizeof(WCHAR));
    MultiByteToWideChar(CP_ACP, 0, s, -1, w, n);
    BSTR b = SysAllocString(w);
    free(w);
    return b;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("usage: sbxpc_getlogs <ip> [startPos endPos]\n");
        return 1;
    }
    const char *ip = argv[1];
    int use_window = (argc >= 4);
    int start = use_window ? atoi(argv[2]) : 0;
    int end = use_window ? atoi(argv[3]) : 0;

    HMODULE dll = LoadLibraryA("SBXPCDLL.dll");
    if (!dll) { printf("LOADFAIL %lu\n", (unsigned long)GetLastError()); return 1; }

    ConnectTcpip_t ConnectTcpip = (ConnectTcpip_t)GetProcAddress(dll, "_ConnectTcpip");
    Disconnect_t Disconnect = (Disconnect_t)GetProcAddress(dll, "_Disconnect");
    GetLastError_t SbGetLastError = (GetLastError_t)GetProcAddress(dll, "_GetLastError");
    EnableDevice_t EnableDevice = (EnableDevice_t)GetProcAddress(dll, "_EnableDevice");
    ReadAllGLogData_t ReadAllGLogData = (ReadAllGLogData_t)GetProcAddress(dll, "_ReadAllGLogData");
    ReadGLogWithPos_t ReadGLogWithPos = (ReadGLogWithPos_t)GetProcAddress(dll, "_ReadGLogWithPos");
    GetAllGLogData_t GetAllGLogData = (GetAllGLogData_t)GetProcAddress(dll, "_GetAllGLogData");

    if (!ConnectTcpip || !Disconnect || !EnableDevice || !ReadAllGLogData || !GetAllGLogData) {
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

    int fetched;
    if (use_window) {
        if (!ReadGLogWithPos) { printf("MISSING_EXPORT ReadGLogWithPos\n"); EnableDevice(1, 1); Disconnect(1); return 1; }
        fetched = ReadGLogWithPos(1, start, end) ? 1 : 0;
        printf("READ window %d-%d -> %d\n", start, end, fetched);
    } else {
        fetched = ReadAllGLogData(1) ? 1 : 0;
        printf("READ all -> %d\n", fetched);
    }
    fflush(stdout);

    if (!fetched) {
        int err = -1;
        if (SbGetLastError) SbGetLastError(1, &err);
        printf("LASTERROR %d\n", err);
        EnableDevice(1, 1);
        Disconnect(1);
        return 3;
    }

    long count = 0;
    while (count < 500000) {
        int tmachine = 0, enroll = 0, emachine = 0, verify = 0;
        int y = 0, mo = 0, d = 0, h = 0, mi = 0, s = 0;
        if (!GetAllGLogData(1, &tmachine, &enroll, &emachine, &verify,
                            &y, &mo, &d, &h, &mi, &s)) break;
        printf("LOG|%d|%d|%04d-%02d-%02d %02d:%02d:%02d\n",
               enroll, verify, y, mo, d, h, mi, s);
        count++;
        if ((count % 5000) == 0) fflush(stdout);
    }
    printf("TOTAL %ld\n", count);

    EnableDevice(1, 1);
    Disconnect(1);
    return 0;
}
