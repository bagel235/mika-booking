import type { Metadata } from "next";
import "./globals.css";
export const metadata: Metadata = { title:"MIKA 预约系统", description:"轻松预约 MIKA 创作空间，实时查看时间与价格。" };
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="zh-CN"><body>{children}</body></html>}
