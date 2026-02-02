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

export interface ViewBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ViewNode {
  id: string;
  type: string;
  bounds: ViewBounds;
  visible: boolean;
  opacity?: number;
  testId?: string;
  text?: string;
  children: Array<string>;
  parentId?: string;
}

export interface SnapshotOptions {
  maxNodes: number;
  maxDepth: number;
  includeText: boolean;
}

export interface ViewTreeSnapshot {
  rootIds: Array<string>;
  nodes: Record<string, ViewNode>;
}

export class ViewRegistry {
  private static _instance: ViewRegistry | null = null;
  private nodes: Map<string, ViewNode> = new Map<string, ViewNode>();
  private rootIds: Set<string> = new Set<string>();

  static get(): ViewRegistry {
    if (ViewRegistry._instance === null) ViewRegistry._instance = new ViewRegistry();
    return ViewRegistry._instance as ViewRegistry;
  }

  register(node: ViewNode): void {
    this.nodes.set(node.id, node);
    if (!node.parentId) this.rootIds.add(node.id);
  }

  update(node: ViewNode): void {
    this.nodes.set(node.id, node);
  }

  unregister(nodeId: string): void {
    const n = this.nodes.get(nodeId);
    if (n && !n.parentId) this.rootIds.delete(nodeId);
    this.nodes.delete(nodeId);
  }

  setParent(childId: string, parentId: string | undefined): void {
    const child = this.nodes.get(childId);
    if (!child) return;
    child.parentId = parentId;
    if (parentId) this.rootIds.delete(childId);
    else this.rootIds.add(childId);
  }

  addChild(parentId: string, childId: string): void {
    const parent = this.nodes.get(parentId);
    const child = this.nodes.get(childId);
    if (!parent || !child) return;
    if (parent.children.indexOf(childId) < 0) parent.children.push(childId);
    child.parentId = parentId;
    this.rootIds.delete(childId);
  }

  snapshot(): ViewTreeSnapshot {
    const nodesOut: Record<string, ViewNode> = {};
    const ids = Array.from(this.nodes.keys());
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const node = this.nodes.get(id) as ViewNode;
      nodesOut[id] = node;
    }
    const roots = Array.from(this.rootIds.values());
    return { rootIds: roots, nodes: nodesOut } as ViewTreeSnapshot;
  }
}


