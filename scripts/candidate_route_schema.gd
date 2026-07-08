extends RefCounted

## CandidateRouteSchema —— 常驻候选路由（candidate route）record/range GPU 缓冲区契约
## schema 的单一事实来源（single source of truth）。
##
## 生产者（ScenePlacementActor / AutoObjectProbePrefilterGPU）打包 record/range 缓冲并把
## schema_version / stride 写入路由契约；消费者（VoxelPlacementGenerator）按同一套常量校验
## 通过后才在 GPU 端绑定。三方都从这里派生本地常量，因此 record/range 的字节布局一旦变更，
## 只需在此处 bump SCHEMA_VERSION，生产者与消费者不可能再各持一份而静默失配。

## 契约 schema 版本。record/range 的 uvec4 字节布局变化时在此 +1；
## VPG 的 bindable 校验会拒绝 schema_version 不一致的契约。
const SCHEMA_VERSION := 1

## 单条 candidate-route record 的字节步幅（schema v1：一个 uvec4，record.x = sparse tile id）。
const RECORD_STRIDE_BYTES := 16

## 单条 candidate-route range 的字节步幅（schema v1：一个 uvec4，range.xy = record_start, record_count）。
const RANGE_STRIDE_BYTES := 16
