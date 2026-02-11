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

import { PageRootDecorator, PageRootHandle } from './PageRootDecorator';
import common from '@ohos.app.ability.common';

export interface WithPageRootOptions {
  id: string;
  type?: string;
  testId?: string;
  getContext: (comp: Object) => common.BaseContext | undefined;
}

export interface ComponentProto {
  aboutToAppear?: (...args: Array<Object>) => Object | void;
  aboutToDisappear?: (...args: Array<Object>) => Object | void;
  onPageShow?: (...args: Array<Object>) => Object | void;
  onPageHide?: (...args: Array<Object>) => Object | void;
  build?: (...args: Array<Object>) => Object | void;
}

export interface ComponentClass {
  prototype: ComponentProto;
}

export function withPageRoot<C extends ComponentClass>(Comp: C, opts: WithPageRootOptions): C {
  // 通过原型扩展组件生命周期，注册/更新/清理 PageRoot
  interface ComponentProtoExt extends ComponentProto, WithOptions, OrigFns {}
  interface ComponentClassExt extends ComponentClass { prototype: ComponentProtoExt }
  const proto = (Comp as ComponentClassExt).prototype as ComponentProtoExt;
  proto.__withPageRootOptions__ = opts;
  // 备份原方法
  proto.__orig_aboutToAppear__ = proto.aboutToAppear;
  proto.__orig_aboutToDisappear__ = proto.aboutToDisappear;
  proto.__orig_onPageShow__ = proto.onPageShow;
  proto.__orig_onPageHide__ = proto.onPageHide;
  proto.__orig_build__ = proto.build;

  // 绑定通用处理器：使用类方法引用，避免函数表达式/箭头函数限制
  const handlers = new PageRootHandlers();
  proto.aboutToAppear = handlers.aboutToAppear;
  proto.aboutToDisappear = handlers.aboutToDisappear;
  proto.onPageShow = handlers.onPageShow;
  proto.onPageHide = handlers.onPageHide;
  proto.build = handlers.build;

  return Comp;
}

// 使用 WeakMap 存储句柄，避免在实例上挂载索引属性
const pageRootHandleMap: WeakMap<Object, PageRootHandle> = new WeakMap<Object, PageRootHandle>();
interface WithOptions { __withPageRootOptions__?: WithPageRootOptions }
interface OrigFns {
  __orig_aboutToAppear__?: (...args: Array<Object>) => Object | void;
  __orig_aboutToDisappear__?: (...args: Array<Object>) => Object | void;
  __orig_onPageShow__?: (...args: Array<Object>) => Object | void;
  __orig_onPageHide__?: (...args: Array<Object>) => Object | void;
  __orig_build__?: (...args: Array<Object>) => Object | void;
}

interface ComponentInstance extends WithOptions, OrigFns {}

function getMeta(self: Object): ComponentInstance {
  return self as ComponentInstance;
}

function ensureHandle(self: Object, opts: WithPageRootOptions): PageRootHandle | undefined {
  try {
    const ctx = opts.getContext(self as Object);
    if (!ctx) return undefined;
    const handle = PageRootDecorator.attach({ id: opts.id, type: opts.type, testId: opts.testId, context: ctx });
    pageRootHandleMap.set(self, handle);
    return handle;
  } catch (_) {
    return undefined;
  }
}

type ComponentMethod = (...args: Array<Object>) => Object | void;

function invokeOriginal(self: Object, fn: ComponentMethod | undefined, args: Array<Object>): Object | void {
  if (!fn) {
    return undefined;
  }
  const bound: ComponentMethod = (fn as ComponentMethod).bind(self) as ComponentMethod;
  return bound(...args);
}

class PageRootHandlers {
  aboutToAppear(this: Object, ...args: Array<Object>): Object | void {
    const meta = getMeta(this);
    const opts = meta.__withPageRootOptions__;
    if (opts) {
      const h = ensureHandle(this, opts);
      try { h?.refreshBounds().catch(() => {}); } catch (_) {}
      try { h?.setVisible(true); } catch (_) {}
    }
    const orig = meta.__orig_aboutToAppear__;
    return invokeOriginal(this, orig, args);
  }

  aboutToDisappear(this: Object, ...args: Array<Object>): Object | void {
    const meta = getMeta(this);
    const h = pageRootHandleMap.get(this as Object);
    try { if (h) h.dispose(); } catch (_) {}
    pageRootHandleMap.delete(this as Object);
    const orig = meta.__orig_aboutToDisappear__;
    return invokeOriginal(this, orig, args);
  }

  onPageShow(this: Object, ...args: Array<Object>): Object | void {
    const meta = getMeta(this);
    const h = pageRootHandleMap.get(this as Object);
    try { h?.setVisible(true); } catch (_) {}
    try { h?.refreshBounds().catch(() => {}); } catch (_) {}
    const orig = meta.__orig_onPageShow__;
    return invokeOriginal(this, orig, args);
  }

  onPageHide(this: Object, ...args: Array<Object>): Object | void {
    const meta = getMeta(this);
    const h = pageRootHandleMap.get(this as Object);
    try { h?.setVisible(false); } catch (_) {}
    const orig = meta.__orig_onPageHide__;
    return invokeOriginal(this, orig, args);
  }

  build(this: Object, ...args: Array<Object>): Object | void {
    const meta = getMeta(this);
    const orig = meta.__orig_build__;
    const ret = invokeOriginal(this, orig, args);
    const h = pageRootHandleMap.get(this as Object);
    try { h?.refreshBounds().catch(() => {}); } catch (_) {}
    return ret as (Object | void);
  }
}


