/*
 * Copyright (C) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import fs from '@ohos.file.fs';
import util from '@ohos.util';

interface AddressRange { start: number; end: number }
interface ProcMapEntry { start: number; end: number; perms: string; path: string }
interface FileIds { codeId?: string; debugId?: string }

export class DebugImage {
  image_addr: string = ""; // hex start address as string
  image_size: number = 0;   // size in bytes
  code_file: string = "";  // path to binary or library
  type: string = "proguard"; // generic type placeholder
  debug_id?: string;        // optional UUID
  code_id?: string;         // optional code id
  debug_file?: string;      // optional debug file path

  constructor(init?: Partial<DebugImage>) {
    if (init) {
      if (typeof init.image_addr === 'string') this.image_addr = init.image_addr;
      if (typeof init.image_size === 'number') this.image_size = init.image_size;
      if (typeof init.code_file === 'string') this.code_file = init.code_file;
      if (typeof init.type === 'string') this.type = init.type;
      if (typeof init.debug_id === 'string') this.debug_id = init.debug_id;
      if (typeof init.code_id === 'string') this.code_id = init.code_id;
      if (typeof init.debug_file === 'string') this.debug_file = init.debug_file;
    }
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {
      'image_addr': this.image_addr as Object,
      'image_size': this.image_size as Object,
      'code_file': this.code_file as Object,
      'type': this.type as Object,
    };
    if (this.debug_id) out['debug_id'] = this.debug_id as Object;
    if (this.code_id) out['code_id'] = this.code_id as Object;
    if (this.debug_file) out['debug_file'] = this.debug_file as Object;
    return out;
  }
}

export class DebugImagesLoader {
  // Enumerate loaded binaries by parsing /proc/self/maps and build DebugImage entries.
  static loadDebugImages(): Array<DebugImage> {
    const mapsText = DebugImagesLoader.readSelfMaps();
    if (!mapsText) return [] as Array<DebugImage>;
    const segments = DebugImagesLoader.parseProcMaps(mapsText);
    // Group by path, compute min start and max end
    const grouped: Record<string, AddressRange> = {};
    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i];
      if (!seg.path || seg.path.length === 0) continue;
      if (seg.path.charAt(0) === '[') continue; // skip [heap]/[stack]/etc
      if (!seg.perms || seg.perms.indexOf('x') < 0) continue; // only executable mappings
      // Limit to shared objects or app binary paths
      const p = seg.path;
      const isShared = p.indexOf('.so') >= 0 || p.indexOf('/lib') >= 0;
      const isAppBin = p.indexOf('/bin/') >= 0 || p.indexOf('/data/') >= 0;
      if (!isShared && !isAppBin) continue;
      if (!grouped[p]) grouped[p] = { start: seg.start, end: seg.end };
      else {
        if (seg.start < grouped[p].start) grouped[p].start = seg.start;
        if (seg.end > grouped[p].end) grouped[p].end = seg.end;
      }
    }
    const out: Array<DebugImage> = [] as Array<DebugImage>;
    const paths = Object.keys(grouped);
    for (let i = 0; i < paths.length; i++) {
      const path = paths[i];
      const r = grouped[path];
      // Prefer real file size if available, otherwise use mapped size
      let size = (r.end > r.start) ? (r.end - r.start) : 0;
      try {
        const st = fs.statSync(path);
        const fileSize = (st.size as number) || 0;
        if (fileSize > 0) size = fileSize;
      } catch (_) {}
      const addrHex = '0x' + DebugImagesLoader.toHex(r.start);
      const hashes = DebugImagesLoader.computeFileIds(path);
      const img = new DebugImage();
      img.image_addr = addrHex;
      img.image_size = size;
      img.code_file = path;
      img.type = 'elf';
      if (hashes.codeId) img.code_id = hashes.codeId;
      if (hashes.debugId) img.debug_id = hashes.debugId;
      img.debug_file = path;
      out.push(img);
    }
    return out;
  }

  // Filter images that contain any of the given instruction addresses.
  static loadDebugImagesForAddresses(addresses: Array<string>): Array<DebugImage> {
    const all = DebugImagesLoader.loadDebugImages();
    if (!addresses || addresses.length === 0) return all;
    const addrs: Array<number> = [] as Array<number>;
    for (let i = 0; i < addresses.length; i++) {
      const s = addresses[i];
      if (!s) continue;
      let n = -1;
      if (s.startsWith('0x') || s.startsWith('0X')) {
        n = DebugImagesLoader.parseHex(s.substring(2));
      } else {
        const dec = DebugImagesLoader.parseDec(s);
        if (dec >= 0) n = dec; else n = DebugImagesLoader.parseHex(s);
      }
      if (n >= 0) addrs.push(n);
    }
    if (addrs.length === 0) return all;
    // Build quick lookup of ranges from images (recompute start/end from addr+size)
    const filtered: Array<DebugImage> = [] as Array<DebugImage>;
    for (let i = 0; i < all.length; i++) {
      const img = all[i];
      const start = DebugImagesLoader.parseHex(img.image_addr.startsWith('0x') ? img.image_addr.substring(2) : img.image_addr);
      const end = (start >= 0 && img.image_size > 0) ? (start + img.image_size) : -1;
      if (start < 0 || end < 0) continue;
      let match = false;
      for (let j = 0; j < addrs.length; j++) {
        const a = addrs[j];
        if (a >= start && a < end) { match = true; break; }
      }
      if (match) filtered.push(img);
    }
    return (filtered.length > 0) ? filtered : all;
  }

  private static readSelfMaps(): string {
    try {
      const path = '/proc/self/maps';
      const stat = fs.statSync(path);
      const size = (stat.size as number) || 0;
      if (size <= 0) return '';
      const file = fs.openSync(path, 0o444);
      const buf = new Uint8Array(size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const decoder = new util.TextDecoder();
      return decoder.decode(buf);
    } catch (_) {
      return '';
    }
  }

  private static parseProcMaps(text: string): Array<ProcMapEntry> {
    const lines = text.split('\n');
    const out: Array<ProcMapEntry> = [] as Array<ProcMapEntry>;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // Format: start-end perms offset dev inode pathname
      // Example: 12c000-13d000 r-xp 00000000 fd:01 12345 /system/lib/libc.so
      const parts = line.trim().split(/\s+/);
      if (parts.length < 5) continue;
      const range = parts[0];
      const hy = range.indexOf('-');
      if (hy <= 0) continue;
      const startHex = range.substring(0, hy);
      const endHex = range.substring(hy + 1);
      const start = DebugImagesLoader.parseHex(startHex);
      const end = DebugImagesLoader.parseHex(endHex);
      if (start < 0 || end < 0) continue;
      const perms = parts[1] || '';
      const path = (parts.length >= 6) ? parts[5] : '';
      out.push({ start: start, end: end, perms: perms, path: path } as ProcMapEntry);
    }
    return out;
  }

  private static parseHex(h: string): number {
    try {
      let n = 0;
      for (let i = 0; i < h.length; i++) {
        const c = h.charCodeAt(i);
        let v = -1;
        if (c >= 48 && c <= 57) v = c - 48;           // 0-9
        else if (c >= 97 && c <= 102) v = 10 + (c - 97); // a-f
        else if (c >= 65 && c <= 70) v = 10 + (c - 65);  // A-F
        else return -1;
        n = (n * 16) + v;
      }
      return n;
    } catch (_) {
      return -1;
    }
  }

  private static toHex(n: number): string {
    if (n <= 0) return '0';
    const hexChars = '0123456789abcdef';
    let x = n;
    let s = '';
    while (x > 0) {
      const d = x % 16;
      s = hexChars.charAt(d) + s;
      x = Math.floor(x / 16);
    }
    return s;
  }

  private static parseDec(s: string): number {
    try {
      let n = 0;
      for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) return -1;
        n = (n * 10) + (c - 48);
      }
      return n;
    } catch (_) {
      return -1;
    }
  }

  // --- Hash / IDs helpers ---
  private static computeFileIds(path: string): FileIds {
    try {
      const maxBytes = 4 * 1024 * 1024; // hash at most first 4MB
      const fd = fs.openSync(path, 0o444);
      const stat = fs.statSync(path);
      const total = (stat.size as number) || 0;
      const toRead = total > 0 ? Math.min(total, maxBytes) : maxBytes;
      const buf = new Uint8Array(toRead);
      fs.readSync(fd.fd, buf);
      fs.closeSync(fd);
      const crcA = DebugImagesLoader.crc32(buf, 0, toRead);
      const codeId = DebugImagesLoader.hex8(crcA).toLowerCase();
      // Mix with path to form a 128-bit hex → UUID-like string
      const enc = new util.TextEncoder();
      const pbytes = enc.encode(path);
      const crcB = DebugImagesLoader.crc32(pbytes, 0, pbytes.length);
      const combined = DebugImagesLoader.hex8(crcA) + DebugImagesLoader.hex8(crcB) + DebugImagesLoader.hex8((crcA ^ crcB) >>> 0) + DebugImagesLoader.hex8(((crcA * 2654435761) >>> 0));
      const hex32 = combined.substring(0, 32).toLowerCase();
      const debugId = `${hex32.substring(0,8)}-${hex32.substring(8,12)}-${hex32.substring(12,16)}-${hex32.substring(16,20)}-${hex32.substring(20,32)}`;
      return { codeId: codeId, debugId: debugId } as FileIds;
    } catch (_) {
      return { } as FileIds;
    }
  }

  private static hex8(n: number): string {
    const s = DebugImagesLoader.toHex(n >>> 0);
    // left pad to 8
    if (s.length >= 8) return s.substring(s.length - 8);
    const z = '00000000';
    return z.substring(0, 8 - s.length) + s;
  }

  private static crc32(data: Uint8Array, offset: number, length: number): number {
    let crc = 0 ^ (-1);
    for (let i = 0; i < length; i++) {
      crc = (crc >>> 8) ^ DebugImagesLoader._crcTable[(crc ^ data[offset + i]) & 0xFF];
    }
    return (crc ^ (-1)) >>> 0;
  }

  private static _crcTable: Array<number> = (() => {
    const table: Array<number> = [] as Array<number>;
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c >>> 0;
    }
    return table;
  })();
}


