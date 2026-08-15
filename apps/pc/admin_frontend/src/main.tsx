import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { RouterProvider } from "react-router"

import { router } from "@/router"
import { ThemeProvider } from "@/lib/theme"

import "@/styles/globals.css"

const queryClient = new QueryClient()

const rootElement = document.getElementById("root")
if (!rootElement) {
  throw new Error("找不到 #root 挂载点，请检查 index.html")
}

createRoot(rootElement).render(
  <StrictMode>
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
)
