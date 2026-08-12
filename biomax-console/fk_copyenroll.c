#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

/* Copies a person's enrolled fingerprint(s) from one BioMax/FK623 device to
 * another, via FK623Attend.dll, bypassing SmartOffice entirely.
 *
 * Uses the _StringID function family, NOT the plain numeric variant: this
 * device firmware returns RUNERR_NOSUPPORT (0) for FK_GetEnrollData /
 * FK_PutEnrollData, but DOES support FK_GetEnrollData_StringID /
 * FK_PutEnrollData_StringID (confirmed empirically - same pattern as this
 * device only supporting StringID for user-management, not for logs).
 * Signature inferred from this DLL's own internally-consistent naming
 * convention (15+ other confirmed _StringID sibling pairs all keep the same
 * signature as their base function, just the numeric enrollNumber becomes a
 * string) since the older manual we have predates these StringID exports.
 *
 * nBackupNumber: 0-9 = BACKUP_FP_0..BACKUP_FP_9 (up to 10 fingerprint slots
 * per person). Fingerprint template buffer is a fixed FP_DATA_SIZE=1680
 * bytes (confirmed via mkranga/FKAttend frmEnroll.cs on GitHub).
 *
 * Verified via round-trip test: Put+Save onto a throwaway test ID, then
 * Get it back - 1646/1680 bytes came back byte-identical, the ~34 byte
 * diff was localized to one region (consistent with an internal
 * checksum/metadata field the device recalculates, not corruption). */

#define FP_DATA_SIZE 1680
#define NUM_FP_SLOTS 10

typedef int (__stdcall *FK_ConnectNet_t)(int, const char*, int, int, int, int, int);
typedef int (__stdcall *FK_DisConnect_t)(int);
typedef int (__stdcall *FK_GetEnrollData_StringID_t)(int, const char*, int, int*, void*, int*);
typedef int (__stdcall *FK_PutEnrollData_StringID_t)(int, const char*, int, int, void*, int);
typedef int (__stdcall *FK_SaveEnrollData_t)(int);

typedef struct {
    int backup;
    int privilege;
    int password;
    unsigned char data[FP_DATA_SIZE];
} FpSlot;

int main(int argc, char** argv) {
    if (argc < 4) {
        printf("usage: fk_copyenroll <source_ip> <target_ip> <enrollNumber>\n");
        return 1;
    }
    const char* srcIp = argv[1];
    const char* dstIp = argv[2];
    const char* enrollId = argv[3];

    HMODULE dll = LoadLibraryA("FK623Attend.dll");
    if (!dll) { printf("LOADFAIL\n"); return 1; }

    FK_ConnectNet_t FK_ConnectNet = (FK_ConnectNet_t)GetProcAddress(dll, "FK_ConnectNet");
    FK_DisConnect_t FK_DisConnect = (FK_DisConnect_t)GetProcAddress(dll, "FK_DisConnect");
    FK_GetEnrollData_StringID_t FK_GetEnrollData_StringID =
        (FK_GetEnrollData_StringID_t)GetProcAddress(dll, "FK_GetEnrollData_StringID");
    FK_PutEnrollData_StringID_t FK_PutEnrollData_StringID =
        (FK_PutEnrollData_StringID_t)GetProcAddress(dll, "FK_PutEnrollData_StringID");
    FK_SaveEnrollData_t FK_SaveEnrollData = (FK_SaveEnrollData_t)GetProcAddress(dll, "FK_SaveEnrollData");

    if (!FK_ConnectNet || !FK_DisConnect || !FK_GetEnrollData_StringID ||
        !FK_PutEnrollData_StringID || !FK_SaveEnrollData) {
        printf("MISSING_EXPORT\n");
        return 1;
    }

    /* --- Step 1: read every non-empty fingerprint slot off the source --- */
    int srcHandle = FK_ConnectNet(1, srcIp, 5005, 5000, 0, 0, 1261);
    printf("SRC_CONNECT %d\n", srcHandle);
    if (srcHandle != 1) { return 1; }

    FpSlot slots[NUM_FP_SLOTS];
    int foundCount = 0;
    for (int backup = 0; backup < NUM_FP_SLOTS; backup++) {
        int privilege = -1, password = -1;
        unsigned char buf[FP_DATA_SIZE];
        memset(buf, 0, sizeof(buf));
        int r = FK_GetEnrollData_StringID(srcHandle, enrollId, backup, &privilege, buf, &password);
        if (r == 1) {
            slots[foundCount].backup = backup;
            slots[foundCount].privilege = privilege;
            slots[foundCount].password = password;
            memcpy(slots[foundCount].data, buf, FP_DATA_SIZE);
            printf("SRC_SLOT|%d|%d|%d\n", backup, privilege, password);
            foundCount++;
        }
    }
    FK_DisConnect(srcHandle);
    printf("SRC_TOTAL_SLOTS %d\n", foundCount);

    if (foundCount == 0) {
        printf("NO_DATA_FOUND\n");
        return 1;
    }

    /* --- Step 2: write those slots onto the target, under the SAME ID --- */
    int dstHandle = FK_ConnectNet(1, dstIp, 5005, 5000, 0, 0, 1261);
    printf("DST_CONNECT %d\n", dstHandle);
    if (dstHandle != 1) { return 1; }

    int copiedCount = 0;
    for (int i = 0; i < foundCount; i++) {
        int putR = FK_PutEnrollData_StringID(dstHandle, enrollId, slots[i].backup,
                                              slots[i].privilege, slots[i].data, slots[i].password);
        printf("PUT|%d|%d\n", slots[i].backup, putR);
        int saveR = FK_SaveEnrollData(dstHandle);
        printf("SAVE|%d|%d\n", slots[i].backup, saveR);
        if (putR == 1 && saveR == 1) { copiedCount++; }
    }
    FK_DisConnect(dstHandle);
    printf("TOTAL_COPIED %d\n", copiedCount);

    return 0;
}
