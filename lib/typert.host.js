/**
 * dsh-notify 的 Host 面 Typert 清单(由 typert-loader 自动扫描注册)。
 * 手写清单,结构与 @deepseek-ai/dsh-typert-generator 产物一致:
 * `./typert` 导出 TYPERT,invocations 的 codec 必须是 zod v4 实例。
 */

import { z } from 'zod'

const kindColorSchema = z.object({
  bg: z.string(),
  fg: z.string(),
})

const configSchema = z.object({
  enabled: z.boolean(),
  mode: z.enum(['system', 'custom', 'off']),
  maxVisible: z.number(),
  durationMs: z.number(),
  browser: z.string(),
  bgColor: z.string(),
  textColor: z.string(),
  colors: z.object({
    completed: kindColorSchema,
    error: kindColorSchema,
    running: kindColorSchema,
    approval: kindColorSchema,
    question: kindColorSchema,
  }),
})

const notifyEventSchema = z.object({
  id: z.string(),
  sessionId: z.string(),
  title: z.string(),
  kind: z.enum(['completed', 'error', 'running', 'approval', 'question']),
  text: z.string(),
  activity: z.string().optional(),
  at: z.number(),
})

const getStateSchema = z.object({
  config: configSchema,
  events: z.array(notifyEventSchema),
})

const updateConfigSchema = z.object({
  config: configSchema,
})

const ackSchema = z.object({
  ok: z.boolean(),
})

const browserSchema = z.object({
  id: z.string(),
  name: z.string(),
  path: z.string(),
})

const listBrowsersSchema = z.object({
  browsers: z.array(browserSchema),
})

const patchSchema = z.record(z.string(), z.unknown())

const _state$codec = { mode: 'strict', typeSymbol: 'dsh-notify#NotifyState', schema: getStateSchema }
const _config$codec = { mode: 'strict', typeSymbol: 'dsh-notify#NotifyConfig', schema: configSchema }
const _patch$codec = { mode: 'strict', typeSymbol: 'dsh-notify#NotifyConfigPatch', schema: patchSchema }
const _ack$codec = { mode: 'strict', typeSymbol: 'dsh-notify#AckResult', schema: ackSchema }
const _browsers$codec = { mode: 'strict', typeSymbol: 'dsh-notify#BrowserList', schema: listBrowsersSchema }

export const TYPERT = {
  package: 'dsh-notify',
  face: 'host',
  schemas: [],
  invocations: [
    {
      id: 'dsh-notify#notify/getState',
      service: 'notify',
      namespace: 'notify',
      method: 'getState',
      invocation: { kind: 'direct' },
      parameters: [],
      result: _state$codec,
    },
    {
      id: 'dsh-notify#notify/updateConfig',
      service: 'notify',
      namespace: 'notify',
      method: 'updateConfig',
      invocation: { kind: 'direct' },
      parameters: [
        { name: 'patch', wire: 'patch', source: 'json', codec: _patch$codec },
      ],
      result: _config$codec,
    },
    {
      id: 'dsh-notify#notify/ackEvents',
      service: 'notify',
      namespace: 'notify',
      method: 'ackEvents',
      invocation: { kind: 'direct' },
      parameters: [
        { name: 'ids', wire: 'ids', source: 'json', codec: { mode: 'strict', typeSymbol: 'dsh-notify#EventIds', schema: z.array(z.string()) } },
      ],
      result: _ack$codec,
    },
    {
      id: 'dsh-notify#notify/listBrowsers',
      service: 'notify',
      namespace: 'notify',
      method: 'listBrowsers',
      invocation: { kind: 'direct' },
      parameters: [],
      result: _browsers$codec,
    },
  ],
  model: {
    services: [
      {
        description: 'dsh-notify 通知服务(ctx.notify):插件配置与通知事件队列。Notification config and event queue service (ctx.notify).',
        summary: 'dsh-notify 通知配置与事件队列服务 (dsh-notify notification config & event queue service)。',
        tags: [],
        jsDoc: '/** dsh-notify 通知配置与事件队列服务(ctx.notify)。dsh-notify notification config & event queue service (ctx.notify). */',
        key: 'notify',
        exportName: 'NotifyService',
        members: [
          {
            kind: 'method',
            name: 'getState',
            signature: 'getState(): NotifyState',
            summary: '读取当前配置与全部未确认通知事件。Read the current config and all unacknowledged notification events.',
            jsDoc: '/**\n * 读取当前配置与全部未确认通知事件。\n * @returns 配置与未确认事件列表。\n * Read the current config and all unacknowledged notification events.\n * @returns The config and unacknowledged events.\n */',
          },
          {
            kind: 'method',
            name: 'updateConfig',
            signature: 'updateConfig(patch: NotifyConfigPatch): NotifyConfig',
            summary: '深合并一份配置补丁并持久化。Deep-merge a config patch and persist it.',
            jsDoc: '/**\n * 深合并一份配置补丁并持久化。\n * @param patch - 配置补丁。\n * @returns 更新后的配置。\n * Deep-merge a config patch and persist it.\n * @param patch - The config patch.\n * @returns The updated config.\n */',
          },
          {
            kind: 'method',
            name: 'ackEvents',
            signature: 'ackEvents(ids: string[]): AckResult',
            summary: '回执已消费的事件 id,防止重复提醒。Acknowledge consumed event ids to prevent duplicate alerts.',
            jsDoc: '/**\n * 回执已消费的事件 id,从队列移除。\n * @param ids - 已展示的事件 id 列表。\n * @returns 回执结果。\n * Acknowledge consumed event ids, removing them from the queue.\n * @param ids - Ids of events already shown.\n * @returns The acknowledgement result.\n */',
          },
        ],
        types: [],
      },
    ],
    events: [],
    objects: [],
  },
}

export default TYPERT
