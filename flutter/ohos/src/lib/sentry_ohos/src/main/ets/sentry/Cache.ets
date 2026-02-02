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

import fileio from '@ohos.fileio';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { SentryBaseEvent } from './SentryEvent';

// 日志标签
const CACHE_TAG = '[Sentry] [Cache]';

// 批量加载配置
const DEFAULT_BATCH_SIZE: number = 10; // 每批加载的 envelope 数量
const BACKGROUND_ROTATION_INTERVAL_MS: number = 60 * 1000; // 后台轮换间隔：1分钟

/**
 * Interface for envelope send status record.
 * Stores the envelope ID and the timestamp when it was successfully sent.
 */
export interface EnvelopeSendStatus {
  id: string;
  sentAt: number; // Unix timestamp in milliseconds
}

/**
 * Interface for the send status storage file content.
 */
interface SendStatusStorage {
  envelopes: Array<EnvelopeSendStatus>;
}

/**
 * Interface for cached raw envelope data.
 * Required by ArkTS to avoid object literal type declarations.
 */
export interface CachedRawEnvelope {
  id: string;
  bytes: Uint8Array;
}

// Retention period for sent envelopes: 3 days in milliseconds
const SENT_ENVELOPE_RETENTION_MS: number = 3 * 24 * 60 * 60 * 1000;

/**
 * Interface for envelope file info used in cache rotation.
 */
interface EnvelopeFileInfo {
  name: string;
  path: string;
  modifiedTime: number;
}

/**
 * Interface for cache statistics.
 * Used by getStats() method.
 */
export interface CacheStats {
  total: number;
  pending: number;
  sent: number;
}

/**
 * Background cache rotator that runs periodically to clean up old envelopes.
 * This prevents blocking the main thread during store operations.
 */
class BackgroundCacheRotator {
  private cache: FileEnvelopeCache;
  private timerId: number | null = null;
  private isRunning: boolean = false;
  private intervalMs: number;

  constructor(cache: FileEnvelopeCache, intervalMs: number = BACKGROUND_ROTATION_INTERVAL_MS) {
    this.cache = cache;
    this.intervalMs = intervalMs;
  }

  /**
   * Start the background rotation timer.
   */
  public start(): void {
    if (this.isRunning) {
      return;
    }
    this.isRunning = true;
    // Background rotation started

    // Use setInterval for periodic execution
    const intervalId = setInterval(() => {
      this.performRotation();
    }, this.intervalMs);
    this.timerId = Number(intervalId);
  }

  /**
   * Stop the background rotation timer.
   */
  public stop(): void {
    if (this.timerId !== null) {
      clearInterval(this.timerId);
      this.timerId = null;
    }
    this.isRunning = false;
    // Background rotation stopped
  }

  /**
   * Perform one rotation cycle.
   */
  private performRotation(): void {
    try {
      // Run rotation in a microtask to avoid blocking
      Promise.resolve().then(() => {
        this.cache.rotateCacheIfNeededAsync().catch((e: Error) => {
          console.error(`${CACHE_TAG} Background rotation failed: ${e}`);
        });
      });
    } catch (e) {
      console.error(`${CACHE_TAG} Background rotation error: ${e}`);
    }
  }
}

export class FileEnvelopeCache {
  private cacheDir: string;
  private dirCreated: boolean = false;
  private sendStatusFile: string;
  private sendStatusCache: Map<string, number> = new Map(); // id -> sentAt timestamp
  private maxCacheItems: number;
  private backgroundRotator: BackgroundCacheRotator | null = null;

  /**
   * Create a new FileEnvelopeCache.
   * @param cacheDir The directory to store cached envelopes
   * @param maxCacheItems Maximum number of cached items (default 30, aligned with Android SDK)
   */
  constructor(cacheDir: string, maxCacheItems: number = 30) {
    this.cacheDir = cacheDir;
    this.maxCacheItems = maxCacheItems;
    this.sendStatusFile = `${cacheDir}/send_status.json`;
    // Try to create directory at construction time
    this.ensureDirExists();
    // Load send status from file
    this.loadSendStatus();
    // Cache initialized
  }

  /**
   * Ensure the cache directory exists. Creates it if needed.
   */
  private ensureDirExists(): void {
    if (this.dirCreated) {
      return;
    }
    try {
      // Check if directory exists
      const exists = fs.accessSync(this.cacheDir);
      if (exists) {
        this.dirCreated = true;
        // Directory already exists
        return;
      }
    } catch (_) {
      // Directory doesn't exist, need to create it
    }
    try {
      // Create directory recursively
      fs.mkdirSync(this.cacheDir, true);
      this.dirCreated = true;
      // Directory created
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to create cache directory: ${e}`);
    }
  }

  store(event: SentryBaseEvent): void {
    // Ensure directory exists before storing
    this.ensureDirExists();
    const path = `${this.cacheDir}/${event.event_id}.json`;
    try {
      const fd = fileio.openSync(path, 0o102, 0o666);
      fileio.writeSync(fd, JSON.stringify(event));
      fileio.closeSync(fd);
      // Event stored
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to store event ${event.event_id}: ${e}`);
    }
  }

  discard(eventId: string): void {
    const path = `${this.cacheDir}/${eventId}.json`;
    try {
      fileio.unlinkSync(path);
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to discard event ${eventId}: ${e}`);
    }
  }

  /**
   * Store raw envelope bytes (for Flutter/Dart events that come as binary).
   * Uses .envelope extension to distinguish from JSON events.
   */
  storeRawEnvelope(envelopeBytes: Uint8Array): string | null {
    this.ensureDirExists();
    // Rotate cache if needed (delete oldest files when limit is reached)
    this.rotateCacheIfNeeded();
    // Generate a unique ID for this envelope
    const id = `env_${Date.now()}_${Math.random().toString(36).substring(2, 10)}`;
    const path = `${this.cacheDir}/${id}.envelope`;
    try {
      const fd = fileio.openSync(path, 0o102, 0o666); // O_CREAT | O_RDWR
      fileio.writeSync(fd, envelopeBytes.buffer.slice(envelopeBytes.byteOffset, envelopeBytes.byteOffset + envelopeBytes.byteLength));
      fileio.closeSync(fd);
      // Raw envelope stored
      return id;
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to store raw envelope: ${e}`);
      return null;
    }
  }

  /**
   * Delete a raw envelope file after successful upload.
   */
  discardRawEnvelope(envelopeId: string): void {
    const path = `${this.cacheDir}/${envelopeId}.envelope`;
    try {
      if (fs.accessSync(path)) {
        fileio.unlinkSync(path);
        // Raw envelope deleted
      }
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to delete raw envelope ${envelopeId}: ${e}`);
    }
    // Also remove from send status cache if present
    if (this.sendStatusCache.has(envelopeId)) {
      this.sendStatusCache.delete(envelopeId);
    }
  }

  /**
   * Mark an envelope as successfully sent by storing its ID and timestamp.
   */
  private markEnvelopeAsSent(envelopeId: string): void {
    const now = Date.now();
    this.sendStatusCache.set(envelopeId, now);
    this.saveSendStatus();
  }

  /**
   * Check if an envelope has been marked as sent.
   */
  isEnvelopeSent(envelopeId: string): boolean {
    return this.sendStatusCache.has(envelopeId);
  }

  /**
   * Load send status from persistent storage file. (Sync version)
   */
  private loadSendStatus(): void {
    try {
      const exists = fs.accessSync(this.sendStatusFile);
      if (!exists) {
        return;
      }
      const stat = fileio.statSync(this.sendStatusFile);
      if (stat.size <= 0) {
        return;
      }
      const fd = fileio.openSync(this.sendStatusFile, 0o0); // O_RDONLY
      const buf = new ArrayBuffer(stat.size);
      const bytesRead = fileio.readSync(fd, buf);
      fileio.closeSync(fd);
      const decoder = new util.TextDecoder("utf-8");
      const u8 = new Uint8Array(buf, 0, bytesRead);
      const content = decoder.decodeWithStream(u8);
      const storage: SendStatusStorage = JSON.parse(content) as SendStatusStorage;
      if (storage.envelopes && Array.isArray(storage.envelopes)) {
        for (let i = 0; i < storage.envelopes.length; i++) {
          const item = storage.envelopes[i];
          this.sendStatusCache.set(item.id, item.sentAt);
        }
        // Send status records loaded
      }
    } catch (e) {
      // File doesn't exist or parse error - start with empty cache
      // No existing send status file
    }
  }

  /**
   * Async version: Load send status from persistent storage file.
   */
  public async loadSendStatusAsync(): Promise<void> {
    try {
      const exists = fs.accessSync(this.sendStatusFile);
      if (!exists) {
        return;
      }
      const stat = await fs.stat(this.sendStatusFile);
      if (stat.size <= 0) {
        return;
      }
      const file = await fs.open(this.sendStatusFile, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const bytesRead = await fs.read(file.fd, buf);
      await fs.close(file);

      const decoder = new util.TextDecoder("utf-8");
      const u8 = new Uint8Array(buf, 0, bytesRead);
      const content = decoder.decodeWithStream(u8);
      const storage: SendStatusStorage = JSON.parse(content) as SendStatusStorage;
      if (storage.envelopes && Array.isArray(storage.envelopes)) {
        for (let i = 0; i < storage.envelopes.length; i++) {
          const item = storage.envelopes[i];
          this.sendStatusCache.set(item.id, item.sentAt);
        }
        // Async send status records loaded
      }
    } catch (e) {
      // No existing send status file
    }
  }

  /**
   * Save send status to persistent storage file. (Sync version)
   */
  private saveSendStatus(): void {
    try {
      const envelopes: Array<EnvelopeSendStatus> = [];
      this.sendStatusCache.forEach((sentAt: number, id: string) => {
        const status: EnvelopeSendStatus = { id: id, sentAt: sentAt };
        envelopes.push(status);
      });
      const storage: SendStatusStorage = { envelopes: envelopes };
      const content = JSON.stringify(storage);
      const fd = fileio.openSync(this.sendStatusFile, 0o102, 0o666); // O_CREAT | O_RDWR
      fileio.writeSync(fd, content);
      fileio.closeSync(fd);
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to save send status: ${e}`);
    }
  }

  /**
   * Async version: Save send status to persistent storage file.
   */
  public async saveSendStatusAsync(): Promise<void> {
    try {
      const envelopes: Array<EnvelopeSendStatus> = [];
      this.sendStatusCache.forEach((sentAt: number, id: string) => {
        const status: EnvelopeSendStatus = { id: id, sentAt: sentAt };
        envelopes.push(status);
      });
      const storage: SendStatusStorage = { envelopes: envelopes };
      const content = JSON.stringify(storage);
      const file = await fs.open(this.sendStatusFile,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      await fs.write(file.fd, content);
      await fs.close(file);
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to save send status async: ${e}`);
    }
  }

  /**
   * Clean up old sent envelopes that have exceeded the retention period (3 days).
   * This should be called at app startup.
   * @returns Number of envelopes cleaned up
   */
  cleanupOldSentEnvelopes(): number {
    const now = Date.now();
    const idsToCleanup: Array<string> = [];

    // Find envelopes that have exceeded retention period
    this.sendStatusCache.forEach((sentAt: number, id: string) => {
      const age = now - sentAt;
      if (age > SENT_ENVELOPE_RETENTION_MS) {
        idsToCleanup.push(id);
      }
    });

    if (idsToCleanup.length === 0) {
      // No old sent envelopes to clean up
      return 0;
    }

    // Cleaning up old sent envelopes

    let cleanedCount = 0;
    for (let i = 0; i < idsToCleanup.length; i++) {
      const id = idsToCleanup[i];
      // Delete the actual envelope file
      const path = `${this.cacheDir}/${id}.envelope`;
      try {
        const exists = fs.accessSync(path);
        if (exists) {
          fileio.unlinkSync(path);
          // Old envelope file deleted
        }
      } catch (e) {
        // File may not exist, that's okay
      }
      // Remove from send status cache
      this.sendStatusCache.delete(id);
      cleanedCount++;
    }

    // Save updated status
    this.saveSendStatus();
    // Old sent envelopes cleaned up
    return cleanedCount;
  }

  /**
   * Get statistics about cached envelopes.
   * Useful for debugging and testing.
   */
  getStats(): CacheStats {
    let totalFiles = 0;
    let sentCount = 0;

    let dir: fileio.Dir | null = null;
    try {
      dir = fileio.opendirSync(this.cacheDir);
      let dirent: fileio.Dirent | null | undefined;
      while ((dirent = dir.readSync()) != null && dirent !== undefined) {
        if (dirent.isFile() && dirent.name.endsWith(".envelope")) {
          totalFiles++;
          const id = dirent.name.replace('.envelope', '');
          if (this.sendStatusCache.has(id)) {
            sentCount++;
          }
        }
      }
      dir.closeSync();
    } catch (e) {
      // Ignore errors
    }

    const stats: CacheStats = {
      total: totalFiles,
      pending: totalFiles - sentCount,
      sent: sentCount
    };
    return stats;
  }

  /**
   * Get list of pending (unsent) envelope IDs without loading file content.
   * This is lightweight and suitable for pagination.
   */
  public pendingEnvelopeIds(): Array<string> {
    const ids: Array<string> = [];
    this.ensureDirExists();

    let dir: fileio.Dir | null = null;
    try {
      dir = fileio.opendirSync(this.cacheDir);
      let dirent: fileio.Dirent | null | undefined;
      while ((dirent = dir.readSync()) != null && dirent !== undefined) {
        if (dirent.isFile() && dirent.name.endsWith(".envelope")) {
          const id = dirent.name.replace('.envelope', '');
          ids.push(id);
        }
      }
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to list pending envelope IDs: ${e}`);
    } finally {
      if (dir) dir.closeSync();
    }
    return ids;
  }

  /**
   * Async load a single envelope by ID.
   * Returns null if not found or failed to load.
   */
  public async loadEnvelopeByIdAsync(id: string): Promise<CachedRawEnvelope | null> {
    const path = `${this.cacheDir}/${id}.envelope`;
    try {
      const exists = fs.accessSync(path);
      if (!exists) {
        return null;
      }
      const stat = await fs.stat(path);
      if (stat.size <= 0) {
        return null;
      }
      const file = await fs.open(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const bytesRead = await fs.read(file.fd, buf);
      await fs.close(file);

      const envelope: CachedRawEnvelope = {
        id: id,
        bytes: new Uint8Array(buf, 0, bytesRead)
      };
      return envelope;
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to load envelope ${id}: ${e}`);
      return null;
    }
  }

  /**
   * Load raw envelopes in batches (pagination support).
   * @param offset Starting index
   * @param limit Maximum number to load (default: DEFAULT_BATCH_SIZE)
   * @returns Array of loaded envelopes
   */
  public async allRawEnvelopesBatchAsync(
    offset: number = 0,
    limit: number = DEFAULT_BATCH_SIZE
  ): Promise<Array<CachedRawEnvelope>> {
    const pendingIds = this.pendingEnvelopeIds();
    const totalPending = pendingIds.length;

    if (offset >= totalPending) {
      return [];
    }

    const endIndex = Math.min(offset + limit, totalPending);
    const batchIds = pendingIds.slice(offset, endIndex);

    // Loading batch

    const envelopes: Array<CachedRawEnvelope> = [];
    for (let i = 0; i < batchIds.length; i++) {
      const id = batchIds[i];
      const envelope = await this.loadEnvelopeByIdAsync(id);
      if (envelope) {
        envelopes.push(envelope);
      }
    }

    // Batch loaded
    return envelopes;
  }

  /**
   * Get all envelope files sorted by modification time (oldest first).
   * Used for cache rotation.
   */
  private getAllEnvelopeFilesSorted(): Array<EnvelopeFileInfo> {
    const files: Array<EnvelopeFileInfo> = [];

    let dir: fileio.Dir | null = null;
    try {
      dir = fileio.opendirSync(this.cacheDir);
      let dirent: fileio.Dirent | null | undefined;
      while ((dirent = dir.readSync()) != null && dirent !== undefined) {
        if (dirent.isFile() && dirent.name.endsWith(".envelope")) {
          const filePath = `${this.cacheDir}/${dirent.name}`;
          try {
            const stat = fileio.statSync(filePath);
            const fileInfo: EnvelopeFileInfo = {
              name: dirent.name,
              path: filePath,
              modifiedTime: stat.mtime
            };
            files.push(fileInfo);
          } catch (e) {
            // File may have been deleted, skip it
          }
        }
      }
      dir.closeSync();
    } catch (e) {
      // Directory doesn't exist or can't be read
    }

    // Sort files by modification time (oldest first)
    files.sort((a: EnvelopeFileInfo, b: EnvelopeFileInfo) => a.modifiedTime - b.modifiedTime);

    return files;
  }

  /**
   * Rotate the cache if the number of files exceeds maxCacheItems. (Sync version)
   * Prioritizes deleting already-sent envelopes first to preserve unsent events.
   * Falls back to deleting oldest unsent envelopes if needed.
   * This is called before storing new envelopes.
   * (Enhanced from Android SDK's CacheStrategy.rotateCacheIfNeeded)
   */
  private rotateCacheIfNeeded(): void {
    const files = this.getAllEnvelopeFilesSorted();
    const length = files.length;

    if (length < this.maxCacheItems) {
      // No rotation needed
      return;
    }

    // Calculate how many files to delete
    // We need to delete enough files so that after adding 1 new file, we're still under the limit
    const totalToDelete = (length - this.maxCacheItems) + 1;

    console.warn(`${CACHE_TAG} Cache is full (${length}/${this.maxCacheItems}). Rotating cache, need to delete ${totalToDelete} files`);

    // Separate files into sent and unsent, both sorted by oldest first
    const sentFiles: Array<EnvelopeFileInfo> = [];
    const unsentFiles: Array<EnvelopeFileInfo> = [];

    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      const id = file.name.replace('.envelope', '');
      if (this.sendStatusCache.has(id)) {
        sentFiles.push(file);
      } else {
        unsentFiles.push(file);
      }
    }

    let deletedCount = 0;

    // Priority 1: Delete oldest SENT files first (they've already been uploaded)
    for (let i = 0; i < sentFiles.length && deletedCount < totalToDelete; i++) {
      const file = sentFiles[i];
      const id = file.name.replace('.envelope', '');

      try {
        fileio.unlinkSync(file.path);
        // Deleted sent envelope for rotation
        this.sendStatusCache.delete(id);
        deletedCount++;
      } catch (e) {
        console.warn(`${CACHE_TAG} Failed to delete sent file: ${file.name}`);
      }
    }

    // Priority 2: If still need to delete more, delete oldest UNSENT files
    if (deletedCount < totalToDelete) {
      console.warn(`${CACHE_TAG} Not enough sent files to delete (${deletedCount}/${totalToDelete}), deleting unsent files`);

      for (let i = 0; i < unsentFiles.length && deletedCount < totalToDelete; i++) {
        const file = unsentFiles[i];

        try {
          fileio.unlinkSync(file.path);
          console.warn(`${CACHE_TAG} Deleted unsent envelope for rotation (data loss): ${file.name}`);
          deletedCount++;
        } catch (e) {
          console.warn(`${CACHE_TAG} Failed to delete unsent file: ${file.name}`);
        }
      }
    }

    // Rotation complete

    // Save updated send status
    this.saveSendStatus();
  }

  /**
   * Async version of cache rotation.
   * Rotates the cache if the number of files exceeds maxCacheItems.
   */
  public async rotateCacheIfNeededAsync(): Promise<void> {
    const files = this.getAllEnvelopeFilesSorted();
    const length = files.length;

    if (length < this.maxCacheItems) {
      return;
    }

    const totalToDelete = (length - this.maxCacheItems) + 1;
    console.warn(`${CACHE_TAG} Async rotation: ${length}/${this.maxCacheItems}, deleting ${totalToDelete} files`);

    // Separate files into sent and unsent
    const sentFiles: Array<EnvelopeFileInfo> = [];
    const unsentFiles: Array<EnvelopeFileInfo> = [];

    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      const id = file.name.replace('.envelope', '');
      if (this.sendStatusCache.has(id)) {
        sentFiles.push(file);
      } else {
        unsentFiles.push(file);
      }
    }

    let deletedCount = 0;

    // Priority 1: Delete oldest SENT files first
    for (let i = 0; i < sentFiles.length && deletedCount < totalToDelete; i++) {
      const file = sentFiles[i];
      const id = file.name.replace('.envelope', '');
      try {
        await fs.unlink(file.path);
        this.sendStatusCache.delete(id);
        deletedCount++;
      } catch (e) {
        // File may already be deleted
      }
    }

    // Priority 2: Delete oldest UNSENT files if needed
    if (deletedCount < totalToDelete) {
      for (let i = 0; i < unsentFiles.length && deletedCount < totalToDelete; i++) {
        const file = unsentFiles[i];
        try {
          await fs.unlink(file.path);
          deletedCount++;
          console.warn(`${CACHE_TAG} Deleted unsent envelope (data loss): ${file.name}`);
        } catch (e) {
          // File may already be deleted
        }
      }
    }

    await this.saveSendStatusAsync();
    // Async rotation complete
  }

  /**
   * Start background cache rotation.
   * Should be called when the app starts.
   */
  public startBackgroundRotation(): void {
    if (!this.backgroundRotator) {
      this.backgroundRotator = new BackgroundCacheRotator(this);
    }
    this.backgroundRotator.start();
  }

  /**
   * Stop background cache rotation.
   * Should be called when the app goes to background or shuts down.
   */
  public stopBackgroundRotation(): void {
    if (this.backgroundRotator) {
      this.backgroundRotator.stop();
    }
  }

  /**
   * Get all cached raw envelopes.
   */
  allRawEnvelopes(): Array<CachedRawEnvelope> {
    const envelopes: Array<CachedRawEnvelope> = [];
    this.ensureDirExists();

    let dir: fileio.Dir | null = null;
    try {
      dir = fileio.opendirSync(this.cacheDir);
      let dirent: fileio.Dirent | null | undefined;
      let fileCount = 0;
      while ((dirent = dir.readSync()) != null && dirent !== undefined) {
        if (dirent.isFile() && dirent.name.endsWith(".envelope")) {
          fileCount++;
          const id = dirent.name.replace('.envelope', '');
          const path = `${this.cacheDir}/${dirent.name}`;
          try {
            const stat = fileio.statSync(path);
            const fileSize = stat.size;
            if (fileSize <= 0) continue;
            const fd = fileio.openSync(path, 0o0); // O_RDONLY
            const buf = new ArrayBuffer(fileSize);
            const bytesRead = fileio.readSync(fd, buf);
            fileio.closeSync(fd);
            const envelope: CachedRawEnvelope = { id: id, bytes: new Uint8Array(buf, 0, bytesRead) };
            envelopes.push(envelope);
          } catch (fileError) {
            console.error(`${CACHE_TAG} Failed to read envelope file ${dirent.name}: ${fileError}`);
          }
        }
      }
      // Envelopes loaded
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to read cache directory for envelopes: ${e}`);
    } finally {
      if (dir) dir.closeSync();
    }
    return envelopes;
  }

  all(): Array<SentryBaseEvent> {
    const events: Array<SentryBaseEvent> = [];
    // Ensure directory exists before reading
    this.ensureDirExists();

    let dir: fileio.Dir | null = null;
    try {
      dir = fileio.opendirSync(this.cacheDir);
      let dirent: fileio.Dirent | null | undefined;
      let fileCount = 0;
      // Note: readSync() returns undefined (not null) at end of iteration in HarmonyOS
      while ((dirent = dir.readSync()) != null && dirent !== undefined) {
        if (dirent.isFile() && dirent.name.endsWith(".json")) {
          fileCount++;
          const path = `${this.cacheDir}/${dirent.name}`;
          // Per-file try-catch: single file failure won't break the loop (Android pattern)
          try {
            const stat = fileio.statSync(path);
            const fileSize = stat.size;
            // Dynamic buffer based on actual file size, with minimum 4KB
            const bufSize = fileSize > 0 ? fileSize : 4096;
            const fd = fileio.openSync(path, 0o0);
            const buf = new ArrayBuffer(bufSize);
            const bytesRead = fileio.readSync(fd, buf);
            fileio.closeSync(fd);
            const decoder = new util.TextDecoder("utf-8");
            const u8 = new Uint8Array(buf, 0, bytesRead);
            const content = decoder.decodeWithStream(u8);
            events.push(JSON.parse(content) as SentryBaseEvent);
            // Cached event loaded
          } catch (fileError) {
            // Log error but continue to next file (Android EnvelopeCache pattern)
            console.error(`${CACHE_TAG} Failed to read file ${dirent.name}: ${fileError}`);
          }
        }
      }
      // Events loaded from cache
    } catch (e) {
      console.error(`${CACHE_TAG} Failed to read cache directory ${this.cacheDir}: ${e}`);
    }
    finally { if (dir) dir.closeSync(); }
    return events;
  }
}
