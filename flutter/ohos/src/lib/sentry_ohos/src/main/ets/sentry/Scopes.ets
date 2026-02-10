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

import { Scope } from './Scope';
import { SentryOptions } from './SentryOptions';

export interface IScopes {
  isNoOp(): boolean;
  getScope(): Scope;
  getIsolationScope(): Scope;
  getGlobalScope(): Scope;
  forkedScopes(creator: string): IScopes;
  forkedCurrentScope(creator: string): IScopes;
  forkedRootScopes(creator: string): IScopes;
  getParentScopes(): IScopes | null;
  isAncestorOf(other: IScopes | null): boolean;
  getOptions(): SentryOptions;
}

export interface IScopesStorage {
  get(): IScopes | null;
  set(scopes: IScopes): void;
}

export class NoOpScopes implements IScopes {
  private _scope: Scope = new Scope();
  isNoOp(): boolean { return true; }
  getScope(): Scope { return this._scope; }
  getIsolationScope(): Scope { return this._scope; }
  getGlobalScope(): Scope { return this._scope; }
  forkedScopes(_creator: string): IScopes { return this; }
  forkedCurrentScope(_creator: string): IScopes { return this; }
  forkedRootScopes(_creator: string): IScopes { return this; }
  getParentScopes(): IScopes | null { return null; }
  isAncestorOf(_other: IScopes | null): boolean { return false; }
  getOptions(): SentryOptions { return new SentryOptions(); }
}

export class NoOpScopesStorage implements IScopesStorage {
  get(): IScopes | null { return null; }
  // ignore stored value
  set(_scopes: IScopes): void {}
}

export class InMemoryScopesStorage implements IScopesStorage {
  private _current: IScopes | null = null;
  get(): IScopes | null { return this._current; }
  set(scopes: IScopes): void { this._current = scopes; }
}


