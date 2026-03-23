import koffi from 'koffi';

const pdh = koffi.load('pdh.dll');

// Constants
const PDH_FMT_DOUBLE = 0x00000200;
const PDH_MORE_DATA = 0x800007D2 | 0; // Ensure signed int32 representation
const ERROR_SUCCESS = 0;

// Struct for formatted counter value
const PDH_FMT_COUNTERVALUE = koffi.struct('PDH_FMT_COUNTERVALUE', {
  CStatus: 'uint32',
  _pad: 'uint32',
  doubleValue: 'double',
});

// FFI function declarations
const PdhOpenQueryW = pdh.func('int32 __stdcall PdhOpenQueryW(void*, uintptr_t, _Out_ void**)');
const PdhCloseQuery = pdh.func('int32 __stdcall PdhCloseQuery(void*)');
const PdhAddEnglishCounterW = pdh.func('int32 __stdcall PdhAddEnglishCounterW(void*, str16, uintptr_t, _Out_ void**)');
const PdhCollectQueryData = pdh.func('int32 __stdcall PdhCollectQueryData(void*)');
const PdhGetFormattedCounterValue = pdh.func('int32 __stdcall PdhGetFormattedCounterValue(void*, uint32, _Out_ uint32*, _Out_ PDH_FMT_COUNTERVALUE*)');
const PdhAddCounterW = pdh.func('int32 __stdcall PdhAddCounterW(void*, str16, uintptr_t, _Out_ void**)');
const PdhExpandWildCardPathW = pdh.func('int32 __stdcall PdhExpandWildCardPathW(void*, str16, void*, _Inout_ uint32*, uint32)');

export interface PdhCounter {
  name: string;
  path: string;
  handle: unknown;
}

export class PdhQuery {
  private queryHandle: unknown = null;
  private counters: PdhCounter[] = [];
  private initialized = false;

  open(): void {
    const handleOut = [null];
    const status = PdhOpenQueryW(null, 0, handleOut);
    if (status !== ERROR_SUCCESS) {
      throw new Error(`PdhOpenQueryW failed with status 0x${status.toString(16)}`);
    }
    this.queryHandle = handleOut[0];
    this.initialized = true;
  }

  addCounter(name: string, counterPath: string): boolean {
    if (!this.initialized) throw new Error('Query not opened');
    const handleOut = [null];
    const status = PdhAddEnglishCounterW(this.queryHandle, counterPath, 0, handleOut);
    if (status !== ERROR_SUCCESS) {
      return false;
    }
    this.counters.push({ name, path: counterPath, handle: handleOut[0] });
    return true;
  }

  expandWildcard(pattern: string): string[] {
    // First call to get required buffer size
    const sizeArr = new Uint32Array(1);
    sizeArr[0] = 0;
    let status = PdhExpandWildCardPathW(null, pattern, null, sizeArr, 0);
    if (status !== PDH_MORE_DATA && status !== ERROR_SUCCESS) {
      return [];
    }

    const bufSize = sizeArr[0];
    if (bufSize === 0) return [];

    // Allocate buffer and expand
    const buf = Buffer.alloc(bufSize * 2);
    sizeArr[0] = bufSize;
    status = PdhExpandWildCardPathW(null, pattern, buf, sizeArr, 0);
    if (status !== ERROR_SUCCESS) {
      return [];
    }

    // Parse multi-string (null-separated, double-null terminated)
    const str = buf.toString('utf16le');
    return str.split('\0').filter(s => s.length > 0);
  }

  addWildcardCounters(namePrefix: string, pattern: string): number {
    const paths = this.expandWildcard(pattern);
    let added = 0;
    for (const p of paths) {
      const match = p.match(/\(([^)]+)\)/);
      const instance = match ? match[1] : String(added);
      // Use PdhAddCounterW (localized) since expanded paths include hostname and localized names
      if (this.addCounterLocalized(`${namePrefix}.${instance}`, p)) {
        added++;
      }
    }
    return added;
  }

  addCounterLocalized(name: string, counterPath: string): boolean {
    if (!this.initialized) throw new Error('Query not opened');
    const handleOut = [null];
    const status = PdhAddCounterW(this.queryHandle, counterPath, 0, handleOut);
    if (status !== ERROR_SUCCESS) {
      return false;
    }
    this.counters.push({ name, path: counterPath, handle: handleOut[0] });
    return true;
  }

  collect(): boolean {
    if (!this.initialized) return false;
    const status = PdhCollectQueryData(this.queryHandle);
    return status === ERROR_SUCCESS;
  }

  getValues(): Record<string, number> {
    const result: Record<string, number> = {};
    const typeOut = new Uint32Array(1);
    const valueOut = { CStatus: 0, _pad: 0, doubleValue: 0 };

    for (const counter of this.counters) {
      const status = PdhGetFormattedCounterValue(
        counter.handle, PDH_FMT_DOUBLE, typeOut, valueOut
      );
      if (status === ERROR_SUCCESS && valueOut.CStatus === 0) {
        result[counter.name] = valueOut.doubleValue;
      }
    }
    return result;
  }

  close(): void {
    if (this.queryHandle) {
      PdhCloseQuery(this.queryHandle);
      this.queryHandle = null;
      this.counters = [];
      this.initialized = false;
    }
  }

  get counterCount(): number {
    return this.counters.length;
  }
}
