import { createBrowserRouter } from "react-router"

import { DashboardPage } from "@/features/dashboard/DashboardPage"
import { ArticleNewPage } from "@/features/articles/ArticleNewPage"
import { ArticleRevisionNewPage } from "@/features/articles/ArticleRevisionNewPage"
import { ArticleStructurePage } from "@/features/articles/ArticleStructurePage"
import { JobsListPage } from "@/features/jobs/JobsListPage"
import { JobDetailPage } from "@/features/jobs/JobDetailPage"
import { VoicesPage } from "@/features/voices/VoicesPage"
import { VoiceNewPage } from "@/features/voices/VoiceNewPage"
import { VoiceBatchPage } from "@/features/voices/VoiceBatchPage"

// 路由表：设计 §5.1。脚手架阶段全部为占位页，功能页按 §12 步骤 4 逐页接入。
export const router = createBrowserRouter([
  { path: "/", element: <DashboardPage /> },
  { path: "/articles/new", element: <ArticleNewPage /> },
  { path: "/articles/:articleId/new-revision", element: <ArticleRevisionNewPage /> },
  { path: "/articles/:articleId/revisions/:revision", element: <ArticleStructurePage /> },
  { path: "/jobs", element: <JobsListPage /> },
  { path: "/jobs/:jobId", element: <JobDetailPage /> },
  { path: "/voices", element: <VoicesPage /> },
  { path: "/voices/new", element: <VoiceNewPage /> },
  { path: "/voices/batches/:batchId", element: <VoiceBatchPage /> },
])
