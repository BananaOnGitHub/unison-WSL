#define WINVER 0x0500

#include <winsock2.h>
#include <windows.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <limits.h>

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <caml/version.h>
#if OCAML_VERSION < 41300
#define CAML_INTERNALS /* was needed from OCaml 4.06 to 4.12 */
#endif
#include <caml/osdeps.h>

/* A compact, audited DEFLATE decoder used only to validate Git's zlib object
 * payloads after they were read through a confined Windows handle.  It is
 * vendored under its retained zlib-style license in ../puff.{c,h}. */
#include "../puff.c"

#if OCAML_VERSION_MAJOR < 5
#define caml_uerror uerror
#define caml_win32_maperr win32_maperr
#define caml_win32_alloc_handle win_alloc_handle
#endif


/* Parts of code in the following section are originally copied from libuv.
 *
 * libuv
 * Copyright Joyent, Inc. and other Node contributors. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */
/* BEGIN section originally copied from libuv win/winapi.h */

typedef struct _IO_STATUS_BLOCK {
  union {
    NTSTATUS Status;
    PVOID Pointer;
  };
  ULONG_PTR Information;
} IO_STATUS_BLOCK, *PIO_STATUS_BLOCK;

/* These native definitions are intentionally local: older Windows SDKs used
 * by supported OCaml/MSVC toolchains do not consistently expose the ntdll
 * declarations required for handle-relative NtCreateFile calls. */
typedef struct _UNISON_UNICODE_STRING {
  USHORT Length;
  USHORT MaximumLength;
  PWSTR Buffer;
} UNISON_UNICODE_STRING, *PUNISON_UNICODE_STRING;

typedef struct _UNISON_OBJECT_ATTRIBUTES {
  ULONG Length;
  HANDLE RootDirectory;
  PUNISON_UNICODE_STRING ObjectName;
  ULONG Attributes;
  PVOID SecurityDescriptor;
  PVOID SecurityQualityOfService;
} UNISON_OBJECT_ATTRIBUTES, *PUNISON_OBJECT_ATTRIBUTES;

typedef struct _FILE_BASIC_INFORMATION {
  LARGE_INTEGER CreationTime;
  LARGE_INTEGER LastAccessTime;
  LARGE_INTEGER LastWriteTime;
  LARGE_INTEGER ChangeTime;
  DWORD FileAttributes;
} FILE_BASIC_INFORMATION, *PFILE_BASIC_INFORMATION;

typedef struct _FILE_STANDARD_INFORMATION {
  LARGE_INTEGER AllocationSize;
  LARGE_INTEGER EndOfFile;
  ULONG         NumberOfLinks;
  BOOLEAN       DeletePending;
  BOOLEAN       Directory;
} FILE_STANDARD_INFORMATION, *PFILE_STANDARD_INFORMATION;

typedef struct _FILE_INTERNAL_INFORMATION {
  LARGE_INTEGER IndexNumber;
} FILE_INTERNAL_INFORMATION, *PFILE_INTERNAL_INFORMATION;

typedef struct _FILE_EA_INFORMATION {
  ULONG EaSize;
} FILE_EA_INFORMATION, *PFILE_EA_INFORMATION;

typedef struct _FILE_ACCESS_INFORMATION {
  ACCESS_MASK AccessFlags;
} FILE_ACCESS_INFORMATION, *PFILE_ACCESS_INFORMATION;

typedef struct _FILE_POSITION_INFORMATION {
  LARGE_INTEGER CurrentByteOffset;
} FILE_POSITION_INFORMATION, *PFILE_POSITION_INFORMATION;

typedef struct _FILE_MODE_INFORMATION {
  ULONG Mode;
} FILE_MODE_INFORMATION, *PFILE_MODE_INFORMATION;

typedef struct _FILE_ALIGNMENT_INFORMATION {
  ULONG AlignmentRequirement;
} FILE_ALIGNMENT_INFORMATION, *PFILE_ALIGNMENT_INFORMATION;

typedef struct _FILE_NAME_INFORMATION {
  ULONG FileNameLength;
  WCHAR FileName[1];
} FILE_NAME_INFORMATION, *PFILE_NAME_INFORMATION;

typedef struct _FILE_DIRECTORY_INFORMATION {
  ULONG NextEntryOffset;
  ULONG FileIndex;
  LARGE_INTEGER CreationTime;
  LARGE_INTEGER LastAccessTime;
  LARGE_INTEGER LastWriteTime;
  LARGE_INTEGER ChangeTime;
  LARGE_INTEGER EndOfFile;
  LARGE_INTEGER AllocationSize;
  ULONG FileAttributes;
  ULONG FileNameLength;
  WCHAR FileName[1];
} FILE_DIRECTORY_INFORMATION, *PFILE_DIRECTORY_INFORMATION;

typedef struct _FILE_ALL_INFORMATION {
  FILE_BASIC_INFORMATION     BasicInformation;
  FILE_STANDARD_INFORMATION  StandardInformation;
  FILE_INTERNAL_INFORMATION  InternalInformation;
  FILE_EA_INFORMATION        EaInformation;
  FILE_ACCESS_INFORMATION    AccessInformation;
  FILE_POSITION_INFORMATION  PositionInformation;
  FILE_MODE_INFORMATION      ModeInformation;
  FILE_ALIGNMENT_INFORMATION AlignmentInformation;
  FILE_NAME_INFORMATION      NameInformation;
} FILE_ALL_INFORMATION, *PFILE_ALL_INFORMATION;

typedef enum _FILE_INFORMATION_CLASS {
  FileDirectoryInformation = 1,
  FileFullDirectoryInformation,
  FileBothDirectoryInformation,
  FileBasicInformation,
  FileStandardInformation,
  FileInternalInformation,
  FileEaInformation,
  FileAccessInformation,
  FileNameInformation,
  FileRenameInformation,
  FileLinkInformation,
  FileNamesInformation,
  FileDispositionInformation,
  FilePositionInformation,
  FileFullEaInformation,
  FileModeInformation,
  FileAlignmentInformation,
  FileAllInformation,
  FileAllocationInformation,
  FileEndOfFileInformation,
  FileAlternateNameInformation,
  FileStreamInformation,
  FilePipeInformation,
  FilePipeLocalInformation,
  FilePipeRemoteInformation,
  FileMailslotQueryInformation,
  FileMailslotSetInformation,
  FileCompressionInformation,
  FileObjectIdInformation,
  FileCompletionInformation,
  FileMoveClusterInformation,
  FileQuotaInformation,
  FileReparsePointInformation,
  FileNetworkOpenInformation,
  FileAttributeTagInformation,
  FileTrackingInformation,
  FileIdBothDirectoryInformation,
  FileIdFullDirectoryInformation,
  FileValidDataLengthInformation,
  FileShortNameInformation,
  FileIoCompletionNotificationInformation,
  FileIoStatusBlockRangeInformation,
  FileIoPriorityHintInformation,
  FileSfioReserveInformation,
  FileSfioVolumeInformation,
  FileHardLinkInformation,
  FileProcessIdsUsingFileInformation,
  FileNormalizedNameInformation,
  FileNetworkPhysicalNameInformation,
  FileIdGlobalTxDirectoryInformation,
  FileIsRemoteDeviceInformation,
  FileAttributeCacheInformation,
  FileNumaNodeInformation,
  FileStandardLinkInformation,
  FileRemoteProtocolInformation,
  FileMaximumInformation
} FILE_INFORMATION_CLASS, *PFILE_INFORMATION_CLASS;

#if !defined(OCAML_VERSION) || OCAML_VERSION < 40300 || OCAML_VERSION >= 41400

typedef struct _REPARSE_DATA_BUFFER {
  ULONG  ReparseTag;
  USHORT ReparseDataLength;
  USHORT Reserved;
  union {
    struct {
      USHORT SubstituteNameOffset;
      USHORT SubstituteNameLength;
      USHORT PrintNameOffset;
      USHORT PrintNameLength;
      ULONG Flags;
      WCHAR PathBuffer[1];
    } SymbolicLinkReparseBuffer;
    struct {
      USHORT SubstituteNameOffset;
      USHORT SubstituteNameLength;
      USHORT PrintNameOffset;
      USHORT PrintNameLength;
      WCHAR PathBuffer[1];
    } MountPointReparseBuffer;
    struct {
      UCHAR  DataBuffer[1];
    } GenericReparseBuffer;
    struct {
      ULONG StringCount;
      WCHAR StringList[1];
    } AppExecLinkReparseBuffer;
  };
} REPARSE_DATA_BUFFER, *PREPARSE_DATA_BUFFER;

#endif /* !OCAML_VERSION */

typedef NTSTATUS (NTAPI *sNtQueryInformationFile)
                 (HANDLE FileHandle,
                  PIO_STATUS_BLOCK IoStatusBlock,
                  PVOID FileInformation,
                  ULONG Length,
                  FILE_INFORMATION_CLASS FileInformationClass);

typedef NTSTATUS (NTAPI *sNtCreateFile)
                 (PHANDLE FileHandle,
                  ACCESS_MASK DesiredAccess,
                  PUNISON_OBJECT_ATTRIBUTES ObjectAttributes,
                  PIO_STATUS_BLOCK IoStatusBlock,
                  PLARGE_INTEGER AllocationSize,
                  ULONG FileAttributes,
                  ULONG ShareAccess,
                  ULONG CreateDisposition,
                  ULONG CreateOptions,
                  PVOID EaBuffer,
                  ULONG EaLength);

typedef NTSTATUS (NTAPI *sNtQueryDirectoryFile)
                 (HANDLE FileHandle,
                  HANDLE Event,
                  PVOID ApcRoutine,
                  PVOID ApcContext,
                  PIO_STATUS_BLOCK IoStatusBlock,
                  PVOID FileInformation,
                  ULONG Length,
                  FILE_INFORMATION_CLASS FileInformationClass,
                  BOOLEAN ReturnSingleEntry,
                  PUNISON_UNICODE_STRING FileName,
                  BOOLEAN RestartScan);

typedef NTSTATUS (NTAPI *sNtSetInformationFile)
                 (HANDLE FileHandle,
                  PIO_STATUS_BLOCK IoStatusBlock,
                  PVOID FileInformation,
                  ULONG Length,
                  FILE_INFORMATION_CLASS FileInformationClass);

typedef BOOLEAN (NTAPI *sRtlDosPathNameToNtPathNameU)
                (PCWSTR DosName,
                 PUNISON_UNICODE_STRING NtName,
                 PCWSTR *FilePart,
                 PVOID RelativeName);

typedef VOID (NTAPI *sRtlFreeUnicodeString)
             (PUNISON_UNICODE_STRING UnicodeString);

typedef ULONG (NTAPI *sRtlNtStatusToDosError)
              (NTSTATUS Status);

sNtQueryInformationFile pNtQueryInformationFile;
sNtCreateFile pNtCreateFile;
sNtQueryDirectoryFile pNtQueryDirectoryFile;
sNtSetInformationFile pNtSetInformationFile;
sRtlDosPathNameToNtPathNameU pRtlDosPathNameToNtPathNameU;
sRtlFreeUnicodeString pRtlFreeUnicodeString;

sRtlNtStatusToDosError pRtlNtStatusToDosError;

#ifndef NT_ERROR
#define NT_ERROR(status) ((((ULONG) (status)) >> 30) == 3)
#endif

#ifndef NT_SUCCESS
#define NT_SUCCESS(status) ((NTSTATUS)(status) >= 0)
#endif

#ifndef OBJ_CASE_INSENSITIVE
#define OBJ_CASE_INSENSITIVE 0x00000040L
#endif

/* OBJ_DONT_REPARSE is not present in older SDK headers.  On a Windows version
 * that does not implement it, NtCreateFile fails and the caller fails closed. */
#ifndef OBJ_DONT_REPARSE
#define OBJ_DONT_REPARSE 0x00001000L
#endif

#ifndef FILE_OPEN
#define FILE_OPEN 0x00000001UL
#endif

#ifndef FILE_CREATE
#define FILE_CREATE 0x00000002UL
#endif

#ifndef FILE_DIRECTORY_FILE
#define FILE_DIRECTORY_FILE 0x00000001UL
#endif

#ifndef FILE_NON_DIRECTORY_FILE
#define FILE_NON_DIRECTORY_FILE 0x00000040UL
#endif

#ifndef FILE_SYNCHRONOUS_IO_NONALERT
#define FILE_SYNCHRONOUS_IO_NONALERT 0x00000020UL
#endif

#ifndef FILE_OPEN_REPARSE_POINT
#define FILE_OPEN_REPARSE_POINT 0x00200000UL
#endif

#ifndef STATUS_NO_MORE_FILES
#define STATUS_NO_MORE_FILES ((NTSTATUS)0x80000006L)
#endif

#ifndef STATUS_OBJECT_NAME_NOT_FOUND
#define STATUS_OBJECT_NAME_NOT_FOUND ((NTSTATUS)0xC0000034L)
#endif

#ifndef STATUS_OBJECT_PATH_NOT_FOUND
#define STATUS_OBJECT_PATH_NOT_FOUND ((NTSTATUS)0xC000003AL)
#endif

#ifndef STATUS_NOT_A_DIRECTORY
#define STATUS_NOT_A_DIRECTORY ((NTSTATUS)0xC0000103L)
#endif

#ifndef STATUS_OBJECT_NAME_COLLISION
#define STATUS_OBJECT_NAME_COLLISION ((NTSTATUS)0xC0000035L)
#endif

/* Linux symlinks exposed by WSL use a Microsoft reparse tag that is not the
 * ordinary Win32 symlink tag.  Treating it as an ordinary file causes lstat
 * to follow it, which is unsafe for a confined workspace scan. */
#ifndef IO_REPARSE_TAG_LX_SYMLINK
#define IO_REPARSE_TAG_LX_SYMLINK (0xA000001D)
#endif

/* END section originally copied from libuv win/winapi.h */

static int nt_init_done = 0;
static int nt_api_available = 0;
static int nt_confined_api_available = 0;

/* BEGIN section originally copied from libuv win/winapi.c */

void win_init()
{
  HMODULE ntdll_module;

  if (nt_init_done) return;

  nt_init_done = 1;

  ntdll_module = GetModuleHandleA("ntdll.dll");
  if (ntdll_module == NULL) {
    nt_api_available = 0;
    return;
  }

  pNtQueryInformationFile = (sNtQueryInformationFile) GetProcAddress(
      ntdll_module, "NtQueryInformationFile");
  if (pNtQueryInformationFile == NULL) {
    nt_api_available = 0;
    return;
  }

  pRtlNtStatusToDosError = (sRtlNtStatusToDosError) GetProcAddress(
      ntdll_module, "RtlNtStatusToDosError");
  if (pRtlNtStatusToDosError == NULL) {
    nt_api_available = 0;
    return;
  }

  nt_api_available = 1;

  pNtCreateFile = (sNtCreateFile) GetProcAddress(ntdll_module, "NtCreateFile");
  pNtQueryDirectoryFile = (sNtQueryDirectoryFile) GetProcAddress(
      ntdll_module, "NtQueryDirectoryFile");
  pNtSetInformationFile = (sNtSetInformationFile) GetProcAddress(
      ntdll_module, "NtSetInformationFile");
  pRtlDosPathNameToNtPathNameU = (sRtlDosPathNameToNtPathNameU) GetProcAddress(
      ntdll_module, "RtlDosPathNameToNtPathName_U");
  pRtlFreeUnicodeString = (sRtlFreeUnicodeString) GetProcAddress(
      ntdll_module, "RtlFreeUnicodeString");
  nt_confined_api_available =
    pNtCreateFile != NULL && pNtQueryDirectoryFile != NULL &&
    pNtSetInformationFile != NULL &&
    pRtlDosPathNameToNtPathNameU != NULL && pRtlFreeUnicodeString != NULL;
}

/* END section originally copied from libuv win/winapi.c */

CAMLprim value win_has_correct_ctime(value unit)
{
  CAMLparam0();

  win_init();

  CAMLreturn (nt_api_available ? Val_true : Val_false);
}

CAMLprim value win_is_reparse_point(value path)
{
  CAMLparam1(path);
  DWORD attributes;
  wchar_t *wpath = caml_stat_strdup_to_utf16(String_val(path));

  attributes = GetFileAttributesW(wpath);
  caml_stat_free(wpath);

  if (attributes == INVALID_FILE_ATTRIBUTES) {
    DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ||
        error == ERROR_INVALID_NAME) {
      CAMLreturn(Val_false);
    }
    caml_win32_maperr(error);
    caml_uerror("is_reparse_point", path);
  }

  CAMLreturn((attributes & FILE_ATTRIBUTE_REPARSE_POINT) ? Val_true : Val_false);
}

/* ------------------------------------------------------------------------- */
/* Read-only confined handles                                                */

/* Git metadata on a WSL UNC share is adversarial input.  These helpers never
 * turn an already checked pathname back into a pathname open:
 *
 *   - the configured root is opened with NtCreateFile and OBJ_DONT_REPARSE;
 *   - every descendant is opened relative to its already-open directory
 *     handle, again with OBJ_DONT_REPARSE and FILE_OPEN_REPARSE_POINT;
 *   - every opened handle is inspected before it can be read or enumerated.
 *
 * We reject every reparse tag rather than maintaining an allow-list.  The
 * only supported objects are ordinary disk files and directories. */

enum unison_confined_kind {
  UNISON_CONFINED_FILE = 0,
  UNISON_CONFINED_DIRECTORY = 1
};

typedef struct unison_confined_handle {
  HANDLE handle;
  int kind;
} unison_confined_handle;

static void unison_confined_finalize(value v)
{
  unison_confined_handle *confined =
    (unison_confined_handle *) Data_custom_val(v);
  if (confined->handle != INVALID_HANDLE_VALUE) {
    (void) CloseHandle(confined->handle);
    confined->handle = INVALID_HANDLE_VALUE;
  }
}

static struct custom_operations unison_confined_handle_ops = {
  "unison.confined_handle",
  unison_confined_finalize,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static void unison_confined_close(unison_confined_handle *confined)
{
  if (confined->handle != INVALID_HANDLE_VALUE) {
    (void) CloseHandle(confined->handle);
    confined->handle = INVALID_HANDLE_VALUE;
  }
}

static int unison_confined_component_valid(value name)
{
  mlsize_t length = caml_string_length(name);
  mlsize_t i;
  const char *bytes = String_val(name);

  if (length == 0 ||
      (length == 1 && bytes[0] == '.') ||
      (length == 2 && bytes[0] == '.' && bytes[1] == '.')) {
    return 0;
  }
  for (i = 0; i < length; i++) {
    if (bytes[i] == '\0' || bytes[i] == '/' || bytes[i] == '\\' ||
        bytes[i] == ':') {
      return 0;
    }
  }
  return 1;
}

static void unison_confined_validate_components(value components)
{
  value list = components;
  while (Is_block(list)) {
    value name = Field(list, 0);
    if (!unison_confined_component_valid(name)) {
      caml_invalid_argument("invalid confined path component");
    }
    list = Field(list, 1);
  }
  if (list != Val_emptylist) {
    caml_invalid_argument("invalid confined path component list");
  }
}

static int unison_confined_missing(NTSTATUS status)
{
  return status == STATUS_OBJECT_NAME_NOT_FOUND ||
         status == STATUS_OBJECT_PATH_NOT_FOUND ||
         status == STATUS_NOT_A_DIRECTORY;
}

typedef struct _UNISON_FILE_RENAME_INFORMATION {
  BOOLEAN ReplaceIfExists;
  HANDLE RootDirectory;
  ULONG FileNameLength;
  WCHAR FileName[1];
} UNISON_FILE_RENAME_INFORMATION, *PUNISON_FILE_RENAME_INFORMATION;

typedef struct _UNISON_FILE_DISPOSITION_INFORMATION {
  BOOLEAN DeleteFile;
} UNISON_FILE_DISPOSITION_INFORMATION, *PUNISON_FILE_DISPOSITION_INFORMATION;

static NTSTATUS unison_confined_nt_create(
  HANDLE root,
  PUNISON_UNICODE_STRING name,
  ACCESS_MASK desired_access,
  ULONG disposition,
  ULONG create_options,
  HANDLE *opened)
{
  UNISON_OBJECT_ATTRIBUTES attributes;
  IO_STATUS_BLOCK io_status;

  attributes.Length = sizeof attributes;
  attributes.RootDirectory = root;
  attributes.ObjectName = name;
  attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
  attributes.SecurityDescriptor = NULL;
  attributes.SecurityQualityOfService = NULL;

  return pNtCreateFile(
    opened,
    desired_access,
    &attributes,
    &io_status,
    NULL,
    FILE_ATTRIBUTE_NORMAL,
    FILE_SHARE_DELETE | FILE_SHARE_READ | FILE_SHARE_WRITE,
    disposition,
    create_options | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
    NULL,
    0);
}

static NTSTATUS unison_confined_nt_open(
  HANDLE root,
  PUNISON_UNICODE_STRING name,
  ULONG create_options,
  HANDLE *opened)
{
  return unison_confined_nt_create(
    root, name, FILE_GENERIC_READ | SYNCHRONIZE, FILE_OPEN,
    create_options, opened);
}

static NTSTATUS unison_confined_delete_handle(HANDLE handle)
{
  IO_STATUS_BLOCK io_status;
  UNISON_FILE_DISPOSITION_INFORMATION disposition;

  disposition.DeleteFile = TRUE;
  return pNtSetInformationFile(handle, &io_status, &disposition,
                               sizeof disposition, FileDispositionInformation);
}

static int unison_confined_validate_handle(HANDLE handle, int *kind, DWORD *error)
{
  BY_HANDLE_FILE_INFORMATION info;

  if (!GetFileInformationByHandle(handle, &info)) {
    *error = GetLastError();
    return 0;
  }

  if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    char buffer[16384];
    DWORD read = 0;
    ULONG tag;

    /* FILE_OPEN_REPARSE_POINT means this query examines the object we opened,
     * rather than a target it might name.  A query failure is also unsafe. */
    if (!DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT,
                         NULL, 0, buffer, sizeof buffer, &read, NULL) ||
        read < sizeof(ULONG)) {
      *error = GetLastError();
      if (*error == ERROR_SUCCESS) *error = ERROR_CANT_ACCESS_FILE;
      return 0;
    }

    /* Deliberately inspect then reject every tag, including
     * IO_REPARSE_TAG_LX_SYMLINK and future/unknown tags. */
    tag = ((PREPARSE_DATA_BUFFER) buffer)->ReparseTag;
    switch (tag) {
      default:
        *error = ERROR_CANT_ACCESS_FILE;
        return 0;
    }
  }

  if (GetFileType(handle) != FILE_TYPE_DISK) {
    *error = ERROR_CANT_ACCESS_FILE;
    return 0;
  }

  *kind = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ?
    UNISON_CONFINED_DIRECTORY : UNISON_CONFINED_FILE;
  return 1;
}

static void unison_confined_raise_nt(NTSTATUS status, const char *operation,
                                     value path)
{
  DWORD error = pRtlNtStatusToDosError(status);
  caml_win32_maperr(error);
  caml_uerror(operation, path);
}

static void unison_confined_raise_win(DWORD error, const char *operation,
                                      value path)
{
  caml_win32_maperr(error);
  caml_uerror(operation, path);
}

/* Read/list receive an opaque custom block rather than an OCaml pathname.
 * Raising a regular Failure here is intentional: callers turn it into a
 * fail-closed unsupported-repository result, without treating the handle bits
 * as a string path in caml_uerror. */
static void unison_confined_fail_handle(const char *operation)
{
  caml_failwith(operation);
}

static value unison_confined_alloc(HANDLE handle, int kind)
{
  CAMLparam0();
  CAMLlocal2(result, option);
  unison_confined_handle *confined;

  result = caml_alloc_custom(&unison_confined_handle_ops,
                             sizeof(unison_confined_handle), 0, 1);
  confined = (unison_confined_handle *) Data_custom_val(result);
  confined->handle = handle;
  confined->kind = kind;
  option = caml_alloc(1, 0);
  Store_field(option, 0, result);
  CAMLreturn(option);
}

static int unison_confined_handle_from_value(value handle_value,
                                             unison_confined_handle **handle)
{
  *handle = (unison_confined_handle *) Data_custom_val(handle_value);
  return (*handle)->handle != INVALID_HANDLE_VALUE;
}

/* Directory handles used as publication roots need only the rights needed to
 * create a child and rename a staged child into that same directory.  Source
 * handles remain read-only. */
#define UNISON_CONFINED_WRITE_DIRECTORY_ACCESS \
  (FILE_GENERIC_READ | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | SYNCHRONIZE)

static NTSTATUS unison_confined_open_directory_access(
  unison_confined_handle *parent_handle, value name, ACCESS_MASK access,
  HANDLE *opened)
{
  wchar_t *wide_name;
  UNISON_UNICODE_STRING name_string;
  NTSTATUS status;

  wide_name = caml_stat_strdup_to_utf16(String_val(name));
  name_string.Buffer = wide_name;
  name_string.Length = (USHORT) (wcslen(wide_name) * sizeof(WCHAR));
  name_string.MaximumLength = name_string.Length;
  status = unison_confined_nt_create(
    parent_handle->handle, &name_string, access, FILE_OPEN,
    FILE_DIRECTORY_FILE, opened);
  caml_stat_free(wide_name);
  return status;
}

CAMLprim value win_confined_open_writable_directory(value parent, value name)
{
  unison_confined_handle *parent_handle;
  HANDLE child = INVALID_HANDLE_VALUE;
  NTSTATUS status;
  int kind;
  DWORD error;
  CAMLparam2(parent, name);

  if (!unison_confined_handle_from_value(parent, &parent_handle)) {
    caml_invalid_argument("closed confined handle");
  }
  if (parent_handle->kind != UNISON_CONFINED_DIRECTORY) {
    unison_confined_raise_win(ERROR_DIRECTORY, "confinedOpenWritableDirectory", name);
  }
  if (!unison_confined_component_valid(name)) {
    caml_invalid_argument("invalid confined path component");
  }
  status = unison_confined_open_directory_access(
    parent_handle, name, UNISON_CONFINED_WRITE_DIRECTORY_ACCESS, &child);
  if (!NT_SUCCESS(status)) {
    if (unison_confined_missing(status)) CAMLreturn(Val_int(0));
    unison_confined_raise_nt(status, "confinedOpenWritableDirectory", name);
  }
  if (!unison_confined_validate_handle(child, &kind, &error)) {
    (void) CloseHandle(child);
    unison_confined_raise_win(error, "confinedOpenWritableDirectory", name);
  }
  if (kind != UNISON_CONFINED_DIRECTORY) {
    (void) CloseHandle(child);
    unison_confined_raise_win(ERROR_DIRECTORY,
                              "confinedOpenWritableDirectory", name);
  }
  CAMLreturn(unison_confined_alloc(child, kind));
}

CAMLprim value win_confined_ensure_directory(value parent, value name)
{
  unison_confined_handle *parent_handle;
  HANDLE child = INVALID_HANDLE_VALUE;
  NTSTATUS status;
  int kind;
  DWORD error;
  wchar_t *wide_name;
  UNISON_UNICODE_STRING name_string;
  CAMLparam2(parent, name);

  if (!unison_confined_handle_from_value(parent, &parent_handle)) {
    caml_invalid_argument("closed confined handle");
  }
  if (parent_handle->kind != UNISON_CONFINED_DIRECTORY) {
    unison_confined_raise_win(ERROR_DIRECTORY, "confinedEnsureDirectory", name);
  }
  if (!unison_confined_component_valid(name)) {
    caml_invalid_argument("invalid confined path component");
  }

  wide_name = caml_stat_strdup_to_utf16(String_val(name));
  name_string.Buffer = wide_name;
  name_string.Length = (USHORT) (wcslen(wide_name) * sizeof(WCHAR));
  name_string.MaximumLength = name_string.Length;
  status = unison_confined_nt_create(
    parent_handle->handle, &name_string, UNISON_CONFINED_WRITE_DIRECTORY_ACCESS,
    FILE_CREATE, FILE_DIRECTORY_FILE, &child);
  caml_stat_free(wide_name);
  if (status == STATUS_OBJECT_NAME_COLLISION) {
    status = unison_confined_open_directory_access(
      parent_handle, name, UNISON_CONFINED_WRITE_DIRECTORY_ACCESS, &child);
  }
  if (!NT_SUCCESS(status)) {
    unison_confined_raise_nt(status, "confinedEnsureDirectory", name);
  }
  if (!unison_confined_validate_handle(child, &kind, &error)) {
    (void) CloseHandle(child);
    unison_confined_raise_win(error, "confinedEnsureDirectory", name);
  }
  if (kind != UNISON_CONFINED_DIRECTORY) {
    (void) CloseHandle(child);
    unison_confined_raise_win(ERROR_DIRECTORY,
                              "confinedEnsureDirectory", name);
  }
  CAMLreturn(unison_confined_alloc(child, kind));
}

static LONG unison_confined_temp_counter = 0;

static int unison_confined_write_all(HANDLE handle, const char *contents,
                                     mlsize_t length)
{
  mlsize_t offset = 0;
  while (offset < length) {
    DWORD written = 0;
    DWORD requested = (DWORD) min((mlsize_t) (1 << 20), length - offset);
    if (!WriteFile(handle, contents + offset, requested, &written, NULL) ||
        written == 0) {
      return 0;
    }
    offset += written;
  }
  return FlushFileBuffers(handle) != 0;
}

static NTSTATUS unison_confined_publish(HANDLE staged, HANDLE directory,
                                        value name)
{
  wchar_t *wide_name;
  size_t name_bytes;
  size_t information_size;
  PUNISON_FILE_RENAME_INFORMATION information;
  IO_STATUS_BLOCK io_status;
  NTSTATUS status;

  wide_name = caml_stat_strdup_to_utf16(String_val(name));
  name_bytes = wcslen(wide_name) * sizeof(WCHAR);
  information_size = offsetof(UNISON_FILE_RENAME_INFORMATION, FileName) +
                     name_bytes;
  information = caml_stat_alloc(information_size);
  information->ReplaceIfExists = FALSE;
  information->RootDirectory = directory;
  information->FileNameLength = (ULONG) name_bytes;
  memcpy(information->FileName, wide_name, name_bytes);
  caml_stat_free(wide_name);
  status = pNtSetInformationFile(staged, &io_status, information,
                                 (ULONG) information_size,
                                 FileRenameInformation);
  caml_stat_free(information);
  return status;
}

/* Stage contents under a fresh process-local name and publish it
 * into [directory] using an NT handle-relative, no-replace rename.  A target
 * race can only produce an existing-name result; it cannot redirect this
 * write through a reparse point or replace an existing object. */
CAMLprim value win_confined_install(value directory, value name, value contents)
{
  unison_confined_handle *directory_handle;
  HANDLE staged = INVALID_HANDLE_VALUE;
  wchar_t temporary[96];
  UNISON_UNICODE_STRING temporary_name;
  NTSTATUS status;
  int kind;
  DWORD error;
  int attempt;
  CAMLparam3(directory, name, contents);

  if (!unison_confined_handle_from_value(directory, &directory_handle)) {
    caml_invalid_argument("closed confined handle");
  }
  if (directory_handle->kind != UNISON_CONFINED_DIRECTORY) {
    unison_confined_raise_win(ERROR_DIRECTORY, "confinedInstall", name);
  }
  if (!unison_confined_component_valid(name)) {
    caml_invalid_argument("invalid confined path component");
  }

  for (attempt = 0; attempt < 32; attempt++) {
    int written = _snwprintf_s(
      temporary, sizeof temporary / sizeof temporary[0], _TRUNCATE,
      L".unison-object-%08lx-%08lx-%08lx",
      (unsigned long) GetCurrentProcessId(), (unsigned long) GetTickCount(),
      (unsigned long) InterlockedIncrement(&unison_confined_temp_counter));
    if (written < 0) {
      unison_confined_fail_handle("confinedInstall could not make a temporary name");
    }
    temporary_name.Buffer = temporary;
    temporary_name.Length = (USHORT) (wcslen(temporary) * sizeof(WCHAR));
    temporary_name.MaximumLength = temporary_name.Length;
    status = unison_confined_nt_create(
      directory_handle->handle, &temporary_name,
      FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | DELETE | SYNCHRONIZE,
      FILE_CREATE, FILE_NON_DIRECTORY_FILE, &staged);
    if (status != STATUS_OBJECT_NAME_COLLISION) break;
  }
  if (!NT_SUCCESS(status)) {
    unison_confined_raise_nt(status, "confinedInstall", name);
  }
  if (!unison_confined_validate_handle(staged, &kind, &error)) {
    (void) unison_confined_delete_handle(staged);
    (void) CloseHandle(staged);
    unison_confined_raise_win(error, "confinedInstall", name);
  }
  if (kind != UNISON_CONFINED_FILE) {
    (void) unison_confined_delete_handle(staged);
    (void) CloseHandle(staged);
    unison_confined_raise_win(ERROR_CANT_ACCESS_FILE, "confinedInstall", name);
  }
  if (!unison_confined_write_all(staged, String_val(contents),
                                 caml_string_length(contents))) {
    error = GetLastError();
    if (error == ERROR_SUCCESS) error = ERROR_WRITE_FAULT;
    (void) unison_confined_delete_handle(staged);
    (void) CloseHandle(staged);
    unison_confined_raise_win(error, "confinedInstall", name);
  }

  status = unison_confined_publish(staged, directory_handle->handle, name);
  if (status == STATUS_OBJECT_NAME_COLLISION) {
    (void) unison_confined_delete_handle(staged);
    (void) CloseHandle(staged);
    CAMLreturn(Val_int(1));
  }
  if (!NT_SUCCESS(status)) {
    (void) unison_confined_delete_handle(staged);
    (void) CloseHandle(staged);
    unison_confined_raise_nt(status, "confinedInstall", name);
  }
  (void) CloseHandle(staged);
  CAMLreturn(Val_int(0));
}

static ULONG unison_adler32(const unsigned char *bytes, unsigned long length)
{
  ULONG a = 1;
  ULONG b = 0;
  while (length != 0) {
    unsigned long chunk = length > 5552 ? 5552 : length;
    length -= chunk;
    while (chunk-- != 0) {
      a += *bytes++;
      b += a;
    }
    a %= 65521;
    b %= 65521;
  }
  return (b << 16) | a;
}

/* Inflate exactly one zlib stream from a larger byte string.  Pack parsing
 * uses the returned byte count to continue at the next object; loose-object
 * validation additionally requires that it consumed the whole input. */
CAMLprim value win_confined_inflate_zlib(value source, value offset_value,
                                         value maximum_value)
{
  mlsize_t length;
  int offset;
  int maximum;
  const unsigned char *input;
  unsigned long available;
  unsigned long consumed;
  unsigned long output_length;
  int puff_result;
  ULONG expected_adler;
  ULONG actual_adler;
  value output;
  CAMLparam3(source, offset_value, maximum_value);
  CAMLlocal2(result, pair);

  offset = Int_val(offset_value);
  maximum = Int_val(maximum_value);
  length = caml_string_length(source);
  if (offset < 0 || maximum < 0 || (mlsize_t) offset > length ||
      length - (mlsize_t) offset < 6 ||
      length - (mlsize_t) offset - 2 > (unsigned long) -1) {
    unison_confined_fail_handle("confinedInflateZlib received invalid input");
  }
  input = (const unsigned char *) String_val(source) + offset;
  if ((input[0] & 0x0f) != 8 || (input[0] >> 4) > 7 ||
      (((unsigned int) input[0] << 8 | input[1]) % 31) != 0 ||
      (input[1] & 0x20) != 0) {
    unison_confined_fail_handle("confinedInflateZlib rejected a zlib header");
  }

  available = (unsigned long) (length - (mlsize_t) offset - 2);
  consumed = available;
  output_length = 0;
  puff_result = puff(NIL, &output_length, input + 2, &consumed);
  if (puff_result != 0 || output_length > (unsigned long) maximum ||
      output_length > INT_MAX || consumed > available ||
      consumed > available - 4) {
    unison_confined_fail_handle("confinedInflateZlib rejected a deflate stream");
  }
  output = caml_alloc_string((mlsize_t) output_length);
  available = (unsigned long) (length - (mlsize_t) offset - 2);
  puff_result = puff((unsigned char *) String_val(output), &output_length,
                     input + 2, &available);
  if (puff_result != 0 || available != consumed) {
    unison_confined_fail_handle("confinedInflateZlib could not reproduce a deflate stream");
  }
  expected_adler = ((ULONG) input[2 + consumed] << 24) |
                   ((ULONG) input[3 + consumed] << 16) |
                   ((ULONG) input[4 + consumed] << 8) |
                   (ULONG) input[5 + consumed];
  actual_adler = unison_adler32((const unsigned char *) String_val(output),
                                output_length);
  if (actual_adler != expected_adler) {
    unison_confined_fail_handle("confinedInflateZlib rejected an Adler-32 checksum");
  }
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, output);
  Store_field(pair, 1, Val_int((int) (2 + consumed + 4)));
  result = pair;
  CAMLreturn(result);
}

CAMLprim value win_confined_open(value root, value components)
{
  HANDLE current = INVALID_HANDLE_VALUE;
  HANDLE child = INVALID_HANDLE_VALUE;
  NTSTATUS status;
  UNISON_UNICODE_STRING root_name;
  wchar_t *root_path;
  value list;
  int kind;
  DWORD error;
  CAMLparam2(root, components);

  win_init();
  if (!nt_confined_api_available) {
    unison_confined_raise_win(ERROR_NOT_SUPPORTED, "confinedOpen", root);
  }

  /* Validate the complete list before obtaining any native handle. */
  unison_confined_validate_components(components);

  root_path = caml_stat_strdup_to_utf16(String_val(root));
  if (!pRtlDosPathNameToNtPathNameU(root_path, &root_name, NULL, NULL)) {
    caml_stat_free(root_path);
    unison_confined_raise_win(ERROR_INVALID_NAME, "confinedOpen", root);
  }
  caml_stat_free(root_path);

  status = unison_confined_nt_open(
    NULL, &root_name, FILE_DIRECTORY_FILE, &current);
  pRtlFreeUnicodeString(&root_name);
  if (!NT_SUCCESS(status)) {
    if (unison_confined_missing(status)) CAMLreturn(Val_int(0));
    unison_confined_raise_nt(status, "confinedOpen", root);
  }
  if (!unison_confined_validate_handle(current, &kind, &error)) {
    (void) CloseHandle(current);
    unison_confined_raise_win(error, "confinedOpen", root);
  }
  if (kind != UNISON_CONFINED_DIRECTORY) {
    (void) CloseHandle(current);
    unison_confined_raise_win(ERROR_DIRECTORY, "confinedOpen", root);
  }

  list = components;
  while (Is_block(list)) {
    value name = Field(list, 0);
    wchar_t *wide_name = caml_stat_strdup_to_utf16(String_val(name));
    UNISON_UNICODE_STRING name_string;
    mlsize_t name_length = caml_string_length(name);

    name_string.Buffer = wide_name;
    name_string.Length = (USHORT) (wcslen(wide_name) * sizeof(WCHAR));
    name_string.MaximumLength = name_string.Length;
    /* The component was validated as non-empty and cannot contain NUL; this
     * guards the UTF-16 conversion above against path truncation. */
    if (name_length == 0 || name_string.Length == 0) {
      caml_stat_free(wide_name);
      (void) CloseHandle(current);
      caml_invalid_argument("invalid confined path component");
    }

    status = unison_confined_nt_open(current, &name_string, 0, &child);
    caml_stat_free(wide_name);
    if (!NT_SUCCESS(status)) {
      (void) CloseHandle(current);
      if (unison_confined_missing(status)) CAMLreturn(Val_int(0));
      unison_confined_raise_nt(status, "confinedOpen", name);
    }
    (void) CloseHandle(current);
    current = child;
    child = INVALID_HANDLE_VALUE;
    if (!unison_confined_validate_handle(current, &kind, &error)) {
      (void) CloseHandle(current);
      unison_confined_raise_win(error, "confinedOpen", name);
    }

    list = Field(list, 1);
    if (Is_block(list) && kind != UNISON_CONFINED_DIRECTORY) {
      (void) CloseHandle(current);
      unison_confined_raise_win(ERROR_DIRECTORY, "confinedOpen", name);
    }
  }

  CAMLreturn(unison_confined_alloc(current, kind));
}

CAMLprim value win_confined_open_child(value parent, value name)
{
  unison_confined_handle *parent_handle;
  HANDLE child = INVALID_HANDLE_VALUE;
  NTSTATUS status;
  wchar_t *wide_name;
  UNISON_UNICODE_STRING name_string;
  int kind;
  DWORD error;
  CAMLparam2(parent, name);

  if (!unison_confined_handle_from_value(parent, &parent_handle)) {
    caml_invalid_argument("closed confined handle");
  }
  if (parent_handle->kind != UNISON_CONFINED_DIRECTORY) {
    unison_confined_raise_win(ERROR_DIRECTORY, "confinedOpenChild", name);
  }
  if (!unison_confined_component_valid(name)) {
    caml_invalid_argument("invalid confined path component");
  }

  wide_name = caml_stat_strdup_to_utf16(String_val(name));
  name_string.Buffer = wide_name;
  name_string.Length = (USHORT) (wcslen(wide_name) * sizeof(WCHAR));
  name_string.MaximumLength = name_string.Length;
  status = unison_confined_nt_open(parent_handle->handle, &name_string, 0, &child);
  caml_stat_free(wide_name);
  if (!NT_SUCCESS(status)) {
    if (unison_confined_missing(status)) CAMLreturn(Val_int(0));
    unison_confined_raise_nt(status, "confinedOpenChild", name);
  }
  if (!unison_confined_validate_handle(child, &kind, &error)) {
    (void) CloseHandle(child);
    unison_confined_raise_win(error, "confinedOpenChild", name);
  }

  CAMLreturn(unison_confined_alloc(child, kind));
}

CAMLprim value win_confined_kind(value handle_value)
{
  unison_confined_handle *handle;
  CAMLparam1(handle_value);

  if (!unison_confined_handle_from_value(handle_value, &handle)) {
    caml_invalid_argument("closed confined handle");
  }
  CAMLreturn(Val_int(handle->kind));
}

CAMLprim value win_confined_read(value handle_value, value maximum_value)
{
  unison_confined_handle *handle;
  LARGE_INTEGER size;
  DWORD read;
  int maximum;
  int offset = 0;
  value contents;
  CAMLparam2(handle_value, maximum_value);
  CAMLlocal1(contents);

  if (!unison_confined_handle_from_value(handle_value, &handle)) {
    caml_invalid_argument("closed confined handle");
  }
  if (handle->kind != UNISON_CONFINED_FILE) {
    unison_confined_fail_handle("confinedRead on a directory handle");
  }
  maximum = Int_val(maximum_value);
  if (maximum < 0) caml_invalid_argument("negative confined read limit");
  if (!GetFileSizeEx(handle->handle, &size))
    unison_confined_fail_handle("confinedRead could not establish a file size");
  if (size.QuadPart < 0 || size.QuadPart > maximum ||
      size.QuadPart > INT_MAX)
    unison_confined_fail_handle("confinedRead rejected an oversized file");

  contents = caml_alloc_string((mlsize_t) size.QuadPart);
  while (offset < size.QuadPart) {
    DWORD requested = (DWORD) min((LONGLONG) 1 << 20, size.QuadPart - offset);
    if (!ReadFile(handle->handle, String_val(contents) + offset,
                  requested, &read, NULL) || read == 0) {
      unison_confined_fail_handle("confinedRead observed a truncated file");
    }
    offset += (int) read;
  }
  /* A handle opened from a file that grew while it was read is not a stable
   * metadata snapshot.  Do not silently consume a prefix. */
  {
    char extra;
    if (!ReadFile(handle->handle, &extra, 1, &read, NULL)) {
      unison_confined_fail_handle("confinedRead could not verify end of file");
    }
    if (read != 0) {
      unison_confined_fail_handle("confinedRead observed a file replacement or growth");
    }
  }
  CAMLreturn(contents);
}

CAMLprim value win_confined_list(value handle_value)
{
  unison_confined_handle *handle;
  char buffer[65536];
  IO_STATUS_BLOCK io_status;
  NTSTATUS status;
  int restart = 1;
  CAMLparam1(handle_value);
  CAMLlocal3(result, entry, name);

  result = Val_emptylist;

  if (!unison_confined_handle_from_value(handle_value, &handle)) {
    caml_invalid_argument("closed confined handle");
  }
  if (handle->kind != UNISON_CONFINED_DIRECTORY) {
    unison_confined_fail_handle("confinedList on a file handle");
  }

  for (;;) {
    ULONG offset = 0;
    ULONG available;
    status = pNtQueryDirectoryFile(
      handle->handle, NULL, NULL, NULL, &io_status, buffer, sizeof buffer,
      FileDirectoryInformation, FALSE, NULL, restart ? TRUE : FALSE);
    restart = 0;
    if (status == STATUS_NO_MORE_FILES) break;
    if (!NT_SUCCESS(status)) {
      unison_confined_fail_handle("confinedList could not enumerate a directory");
    }
    if (io_status.Information > sizeof buffer) {
      unison_confined_fail_handle("confinedList received invalid directory data");
    }
    available = (ULONG) io_status.Information;
    if (available < offsetof(FILE_DIRECTORY_INFORMATION, FileName)) {
      unison_confined_fail_handle("confinedList received invalid directory data");
    }

    for (;;) {
      PFILE_DIRECTORY_INFORMATION info;
      WCHAR *wide_name;
      ULONG wide_length;

      if (offset > available - offsetof(FILE_DIRECTORY_INFORMATION, FileName)) {
        unison_confined_fail_handle("confinedList received invalid directory data");
      }
      info = (PFILE_DIRECTORY_INFORMATION) (buffer + offset);
      if (info->FileNameLength > available - offset -
          offsetof(FILE_DIRECTORY_INFORMATION, FileName) ||
          info->FileNameLength % sizeof(WCHAR) != 0) {
        unison_confined_fail_handle("confinedList received invalid directory data");
      }
      wide_length = info->FileNameLength / sizeof(WCHAR);
      wide_name = caml_stat_alloc((wide_length + 1) * sizeof(WCHAR));
      memcpy(wide_name, info->FileName, info->FileNameLength);
      wide_name[wide_length] = L'\0';
      name = caml_copy_string_of_utf16(wide_name);
      caml_stat_free(wide_name);
      entry = caml_alloc(2, 0);
      Store_field(entry, 0, name);
      Store_field(entry, 1, result);
      result = entry;

      if (info->NextEntryOffset == 0) break;
      if (info->NextEntryOffset > available - offset) {
        unison_confined_fail_handle("confinedList received invalid directory data");
      }
      offset += info->NextEntryOffset;
    }
  }

  CAMLreturn(result);
}

CAMLprim value win_confined_close(value handle_value)
{
  unison_confined_handle *handle;
  CAMLparam1(handle_value);

  handle = (unison_confined_handle *) Data_custom_val(handle_value);
  unison_confined_close(handle);
  CAMLreturn(Val_unit);
}

#define MAKEDWORDLONG(a,b) ((DWORDLONG)(((DWORD)(a))|(((DWORDLONG)((DWORD)(b)))<<32)))
#define WINTIME_TO_TIME(t) ((((ULONGLONG) t) - 116444736000000000ull) / 10000000ull)
#define FILETIME_TO_TIME(ft) WINTIME_TO_TIME((((ULONGLONG) ft.dwHighDateTime) << 32) + ft.dwLowDateTime)
#define FILETIME_NT_TO_TIME(ft) WINTIME_TO_TIME(ft.QuadPart)

CAMLprim value win_stat(value path, value lstat)
{
  uintnat dev;
  uintnat ino;
  uintnat kind;
  uintnat mode;
  uintnat nlink;
  uint64_t size = 0;
  double atime;
  double mtime;
  double ctime;
  int syml = 0;

  int res;
  NTSTATUS nt_status;
  HANDLE h;
  BY_HANDLE_FILE_INFORMATION info;
  IO_STATUS_BLOCK io_status;
  FILE_ALL_INFORMATION file_info;
  CAMLparam2(path, lstat);
  CAMLlocal1 (v);
  char *fname = Bool_val(lstat) ? "lstat" : "stat";

  win_init();

  wchar_t *wpath = caml_stat_strdup_to_utf16(String_val(path));

  h = CreateFileW (wpath, FILE_READ_ATTRIBUTES,
                   FILE_SHARE_DELETE | FILE_SHARE_READ | FILE_SHARE_WRITE,
                   NULL, OPEN_EXISTING,
                   FILE_FLAG_BACKUP_SEMANTICS | FILE_ATTRIBUTE_READONLY |
                   (Bool_val(lstat) ? FILE_FLAG_OPEN_REPARSE_POINT : 0), NULL);
  caml_stat_free(wpath);

  if (h == INVALID_HANDLE_VALUE) {
    caml_win32_maperr(GetLastError());
    caml_uerror(fname, path);
  }

  if (nt_api_available) {
    nt_status = pNtQueryInformationFile(h, &io_status, &file_info,
                                        sizeof file_info, FileAllInformation);

    /* Buffer overflow (a warning status code) is expected here. */
    if (NT_ERROR(nt_status)) {
      caml_win32_maperr(pRtlNtStatusToDosError(nt_status));
      (void) CloseHandle(h);
      caml_uerror(fname, path);
    }
  }

  res = GetFileInformationByHandle (h, &info);
  if (res == 0) {
    caml_win32_maperr(GetLastError());
    (void) CloseHandle (h);
    caml_uerror(fname, path);
  }

  if (Bool_val(lstat) &&
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    /* The following code is partially copied from OCaml sources,
     * LGPL 2.1,
     * Copyright David Allsopp, MetaStack Solutions Ltd. */
    char buffer[16384];
    DWORD read;

    if (DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, NULL, 0, buffer, 16384, &read, NULL)) {
      ULONG tag = ((REPARSE_DATA_BUFFER*)buffer)->ReparseTag;
      if (tag == IO_REPARSE_TAG_SYMLINK || tag == IO_REPARSE_TAG_LX_SYMLINK) {
        syml = 1;
        if (tag == IO_REPARSE_TAG_SYMLINK) {
          size = ((REPARSE_DATA_BUFFER*)buffer)->SymbolicLinkReparseBuffer.SubstituteNameLength / 2;
        }
      }
    }
  }

  res = CloseHandle (h);
  if (res == 0) {
    caml_win32_maperr(GetLastError());
    caml_uerror(fname, path);
  }

  if (Bool_val(lstat) && !syml) {
    CAMLreturn(win_stat(path, Val_false));
  }

  dev = info.dwVolumeSerialNumber;

  if (nt_api_available) {
    /* Use the same hashing formula as the original code */
    ino = ((DWORDLONG)file_info.InternalInformation.IndexNumber.QuadPart) +
      155825701*((DWORDLONG)file_info.InternalInformation.IndexNumber.HighPart);

    kind = file_info.BasicInformation.FileAttributes & FILE_ATTRIBUTE_DIRECTORY ? 1: 0;

    mode = 0000444;
    if (!(file_info.BasicInformation.FileAttributes & FILE_ATTRIBUTE_READONLY))
      mode |= 0000222;
    if (file_info.BasicInformation.FileAttributes & FILE_ATTRIBUTE_DIRECTORY)
      mode |= 0000111;

    nlink = file_info.StandardInformation.NumberOfLinks;
    if (!syml) {
      size = file_info.StandardInformation.EndOfFile.QuadPart;
    }
    atime = (double) FILETIME_NT_TO_TIME(file_info.BasicInformation.LastAccessTime);
    mtime = (double) FILETIME_NT_TO_TIME(file_info.BasicInformation.LastWriteTime);
    if (file_info.BasicInformation.ChangeTime.QuadPart != 0) {
      ctime = (double) FILETIME_NT_TO_TIME(file_info.BasicInformation.ChangeTime);
    } else {
      ctime = (double) FILETIME_NT_TO_TIME(file_info.BasicInformation.CreationTime);
    }
  } else {
    // Apparently, we cannot trust the inode number to be stable when
    // nFileIndexHigh is 0.
    if (info.nFileIndexHigh == 0) info.nFileIndexLow = 0;
    /* The ocaml code truncates inode numbers to 31 bits.  We hash the
       low and high parts in order to lose as little information as
       possible. */
    ino = MAKEDWORDLONG(info.nFileIndexLow,info.nFileIndexHigh)+155825701*((DWORDLONG)info.nFileIndexHigh);

    kind = info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ? 1: 0;

    mode = 0000444;
    if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
      mode |= 0000111;
    if (!(info.dwFileAttributes & FILE_ATTRIBUTE_READONLY))
      mode |= 0000222;

    nlink = info.nNumberOfLinks;
    if (!syml) {
      size = MAKEDWORDLONG(info.nFileSizeLow,info.nFileSizeHigh);
    }
    atime = (double) FILETIME_TO_TIME(info.ftLastAccessTime);
    mtime = (double) FILETIME_TO_TIME(info.ftLastWriteTime);
    ctime = (double) FILETIME_TO_TIME(info.ftCreationTime);
  }

  if (syml) {
    kind = 4;
    mode |= 0000111 | 0000444;
  }

  v = caml_alloc (12, 0);
  Store_field(v, 0, Val_int(dev));
  Store_field(v, 1, Val_int(ino));
  Store_field(v, 2, Val_int(kind));
  Store_field(v, 3, Val_int(mode));
  Store_field(v, 4, Val_int(nlink));
  Store_field(v, 5, Val_int(0));
  Store_field(v, 6, Val_int(0));
  Store_field(v, 7, Val_int(0));
  Store_field(v, 8, caml_copy_int64(size));
  Store_field(v, 9, caml_copy_double(atime));
  Store_field(v, 10, caml_copy_double(mtime));
  Store_field(v, 11, caml_copy_double(ctime));

  CAMLreturn (v);
}

/****/

static value win_hasconsole_gui_msg(DWORD h, const char *s)
{
  const char *u = "This is a GUI-only executable. Text console output "
                  "is not supported. To get text output, use the "
                  "executable intended for it (usually called unison.exe "
                  "or unison-text.exe) or redirect the output.";

  if (!GetFileType((HANDLE) GetStdHandle(h))) {
    MessageBoxA(NULL, strcmp(s, "") != 0 ? s : u, "Information", MB_OK);
    return Val_false;
  } else {
    return Val_true;
  }
}

CAMLprim value win_hasconsole_gui_stdout(value s)
{
  CAMLparam1(s);
  CAMLreturn(win_hasconsole_gui_msg(STD_OUTPUT_HANDLE, String_val(s)));
}

CAMLprim value win_hasconsole_gui_stderr(value s)
{
  CAMLparam1(s);
  CAMLreturn(win_hasconsole_gui_msg(STD_ERROR_HANDLE, String_val(s)));
}

CAMLprim value win_init_console(value unit)
{
  CAMLparam0();
  CAMLlocal2(ret, tmp);
  HANDLE in, out, err, in_orig, out_orig, err_orig;
  FILE *ign;

  ret = caml_alloc_tuple(3);
  Store_field(ret, 0, Val_int(0));
  Store_field(ret, 1, Val_int(0));
  Store_field(ret, 2, Val_int(0));

  in_orig = (HANDLE) GetStdHandle(STD_INPUT_HANDLE);
  out_orig = (HANDLE) GetStdHandle(STD_OUTPUT_HANDLE);
  err_orig = (HANDLE) GetStdHandle(STD_ERROR_HANDLE);

  /* What is going on here... Due to what is arguably a bug in Windows, when
   * stdout and stderr share the same fd/handle inherited by the process, only
   * stdout is closed and cleared for GUI applications without console at
   * process startup. This situation is not something that usually happens in
   * Windows. It seems to happen only when an application is started by a
   * Cygwin/MSYS2 shell (maybe further depending on in which context the shell
   * itself is running). It may also happen when the parent process has marked
   * the handle as not inheritable and then still instructs the child process
   * to use this handle, which is clearly a bug in the parent.
   *
   * This is what happens when stdout and stderr share the same handle.
   *
   * For GUI applications without console (and without redirections) Windows
   * closes and clears stdin, stdout and stderr handles at startup. Since
   * stdout is closed first, stderr has become invalid and since it's invalid,
   * Windows does not close and clear stderr. The handle still set as stderr
   * value (remember, it is now actually closed and free for kernel to reuse)
   * is then later given by kernel to whatever happens to require a new handle.
   *
   * The application has now started and has no idea that something's wrong.
   * AllocConsole() sees that stderr already has a handle set and does not set
   * a new handle for stderr (as it should for a newly allocated console).
   *
   * Now, when trying to use stderr in any way (writing to it, or doing
   * dup/dup2), it may fail in unexpected ways or even cause corruption because
   * the handle is invalid or it could have been reused for anything. In any
   * case, it will likely lead to a crash.
   *
   * It's not possible to detect this situation completely reliably because by
   * the time the application code runs, stdout has already been cleared and
   * the stderr handle could have been reused for anything and our checks could
   * be returning valid values (so it becomes indistinguishable from a
   * redirected stderr). The only way we can detect if something like this is
   * happening, is to check if stdout is cleared but stderr is not and stderr
   * is invalid. Interestingly, at least newer versions of CRT (don't know
   * about UCRT) get this right and correctly report both stdout and stderr as
   * not set. We can leverage this to make the check that much more reliable.
   *
   * We only do this check for stderr because we don't otherwise expect to have
   * invalid std handles which are not NULL. */
  if (err_orig && !out_orig
      && ((!GetFileType(err_orig) && (ERROR_INVALID_HANDLE == GetLastError()))
          || (_fileno(stderr) == -2))) {
    SetStdHandle(STD_ERROR_HANDLE, NULL);
    err_orig = NULL;
  }

  if (!GetFileType(out_orig) || !GetFileType(err_orig)) {
    AllocConsole();
    /* There's nothing we can do about an error, so we're not going to check.
     * Already having a console returns an error, which we want to ignore. */
    if (GetStdHandle(STD_ERROR_HANDLE) == NULL) {
      MessageBoxW(NULL, L"Unable to open a console where debugging output "
                         "will be sent. The program will most likely crash "
                         "when trying to produce debugging output.\n\n"
                         "If the problem persists then remove any \"debug\" "
                         "preferences from the profile, use the text UI or "
                         "redirect standard output and error.",
                  L"Error", MB_OK | MB_ICONWARNING);
    }

    /* Windows C runtime fds for stdin, stdout, stderr are not restored
     * automatically. */
    if (_fileno(stdin) < 0) freopen_s(&ign, "CONIN$", "r", stdin);
    if (_fileno(stdout) < 0) freopen_s(&ign, "CONOUT$", "w", stdout);
    if (_fileno(stderr) < 0) freopen_s(&ign, "CONOUT$", "w", stderr);

    /* AllocConsole() is supposed to init these handles. */
    in = (HANDLE) GetStdHandle(STD_INPUT_HANDLE);
    out = (HANDLE) GetStdHandle(STD_OUTPUT_HANDLE);
    err = (HANDLE) GetStdHandle(STD_ERROR_HANDLE);

    /* Return only handles that are not already redirected by user. */
    if (!GetFileType(in_orig) && (in != in_orig)) {
      tmp = caml_alloc(1, 0);
      Store_field(tmp, 0, caml_win32_alloc_handle(in));
      Store_field(ret, 0, tmp);
    }
    if (!GetFileType(out_orig) && (out != out_orig)) {
      tmp = caml_alloc(1, 0);
      Store_field(tmp, 0, caml_win32_alloc_handle(out));
      Store_field(ret, 1, tmp);
    }
    if (!GetFileType(err_orig) && (err != err_orig)) {
      tmp = caml_alloc(1, 0);
      Store_field(tmp, 0, caml_win32_alloc_handle(err));
      Store_field(ret, 2, tmp);
    }
  }

  CAMLreturn(ret);
}

static HANDLE conin = INVALID_HANDLE_VALUE;

static void init_conin ()
{
  if (conin == INVALID_HANDLE_VALUE) {
    conin = CreateFile ("CONIN$", GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                        OPEN_EXISTING, 0, 0);
    if (conin == INVALID_HANDLE_VALUE) {
      caml_win32_maperr(GetLastError());
      caml_uerror("init_conin", Nothing);
    }
  }
}

CAMLprim value win_get_console_mode (value unit)
{
  CAMLparam0();
  DWORD mode;
  BOOL res;

  init_conin ();

  res = GetConsoleMode (conin, &mode);
  if (res == 0) {
    caml_win32_maperr(GetLastError());
    caml_uerror("get_console_mode", Nothing);
  }

  CAMLreturn(Val_int(mode));
}

CAMLprim value win_set_console_mode (value mode)
{
  CAMLparam1(mode);
  BOOL res;

  init_conin ();

  res = SetConsoleMode (conin, Int_val(mode));
  if (res == 0) {
    caml_win32_maperr(GetLastError());
    caml_uerror("set_console_mode", Nothing);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value win_get_console_output_cp (value unit) {
  CAMLparam0();
  CAMLreturn(Val_int(GetConsoleOutputCP()));
}

CAMLprim value win_set_console_output_cp (value cp) {
  CAMLparam1(cp);
  BOOL res;
  res = SetConsoleOutputCP (Int_val (cp));
  if (res == 0) {
    caml_win32_maperr(GetLastError());
    caml_uerror("set_console_cp", Nothing);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value win_vt_capable(value fd)
{
  CAMLparam1(fd);
  DWORD mode;

  if (Handle_val(fd) == INVALID_HANDLE_VALUE) {
    CAMLreturn(Val_int(0));
  }

  if (!GetConsoleMode(Handle_val(fd), &mode)) {
    CAMLreturn(Val_int(0));
  }

  CAMLreturn(Val_int(mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING));
}
