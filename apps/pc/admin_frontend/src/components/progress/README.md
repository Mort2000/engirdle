# components/progress/

任务进度组件（设计 §6.4、§8）：

- `Stepper`：8 阶段步进条，自建（flex + 视觉 token，含横向滚动适配）；
  完成=实心（对勾）、当前=强调色描边、未到=灰（§6.3）。
- 阶段内百分比 Progress 复用 `components/ui/progress`；无单元刻度阶段用
  indeterminate 动画（`animate-progress-indeterminate`，定义于 globals.css）。
- 进度计算纯函数（权重与后端 §8.1 一致）见 `lib/progress.ts`。
