# MIKA 预约系统

面向客户与店员的生产型预约系统。Next.js 前端共享同一套 Supabase PostgreSQL 预约引擎；价格、有效 HOLD、容量与写入均由数据库服务器时间和事务函数最终裁决。

## 功能

- `/book`：移动优先预约向导、实时余量、数据库价格预览
- `/book/confirmation/[token]`：安全令牌查询、15 分钟倒计时与人工付款说明
- `/admin/calendar`：每周 09:00–24:00 容量视图及预约详情
- `/admin/bookings`：待确认定金、确认收款与取消
- `/admin/settings`：营业规则、定金、付款说明及节假日
- `/admin/new`：使用同一事务引擎手动登记
- `/admin/import`：CSV 全量预检、导入与错误报告
- `/timetable`：无个人信息的今日/本周占用表
- Supabase Auth、RLS、Realtime、原子创建与改期函数

## 本地运行

要求 Node.js 22、Supabase CLI（运行数据库测试时）及一个 Supabase 项目。

```bash
npm install
cp .env.example .env.local
supabase db reset
npm run dev
```

在 `.env.local` 填写 Supabase 项目 URL 与 anon key。迁移位于 `supabase/migrations/`。在 Supabase Authentication 创建店员用户后，用该账号访问 `/admin`。

连接现有 Supabase 项目并应用迁移：

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

首次店员账号：在 Supabase Dashboard → Authentication → Users 中创建邮箱密码用户，复制其 UUID，再在 SQL Editor 执行：

```sql
insert into public.profiles (id, display_name, role)
values ('AUTH_USER_UUID', '店员姓名', 'ADMIN');
```

仅创建 Auth 用户不会获得后台权限；必须存在对应 `profiles` 记录。

## 导入现有数据

1. 登录 `/admin`，进入“数据导入”。
2. 下载 CSV 模板，使用 Excel、Numbers 或表格软件填写后另存为 UTF-8 CSV。
3. 选择文件，先检查有效、错误和重复数据，再点击导入。
4. `CONFIRMED` 会通过共享的事务与容量校验；`COMPLETED`、`CANCELLED` 保存历史记录但不占用容量。
5. 容量冲突等数据库错误可下载为 CSV 报告。

`booking_type` 可填 `SINGLE`、`DOUBLE`、`TRIPLE` 或 `PRIVATE`。三人预约按一个普通组占用容量；价格始终由当前双人价格乘以 1.5 自动计算，不设置独立三人价。

## 并发设计

`slot_inventory(booking_date, slot_start)` 是确定性的事务锁目标。创建预约会先补齐库存行，再按日期和时间顺序 `FOR UPDATE` 锁定全部时段；随后使用 `clock_timestamp()` 判断有效 HOLD，并在同一事务内验证所有时段、写入 booking 与 booking_slots。任一时段失败即整体回滚。客户与店员调用同一函数，Realtime 只刷新界面。

改期会同时锁定旧、新库存行；新时段不可用时整个函数回滚，原预约不变。过期 HOLD 即使尚未清理，也会立即从可用量中排除。

## 测试

```bash
supabase test db
DATABASE_URL='postgresql://...' bash supabase/tests/concurrency/last-slot.sh
npm run build
```

SQL 测试覆盖指定价格样例、容量、包场、过期/取消释放、多小时与营业边界。并发脚本并行争抢最后一个普通容量，断言恰好一个成功。

## 部署到 Vercel

1. 将仓库推送到 GitHub，并在 Vercel 导入。
2. 添加 `NEXT_PUBLIC_SUPABASE_URL`、`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`。
3. 在 Supabase 执行迁移，并将 Vercel 域名加入 Auth 的 Site URL / Redirect URLs。
4. 部署；Vercel 按 `vercel.json` 识别 Next.js。

生产前请为首位管理员在 `profiles` 写入对应 `auth.users.id`，并设置 Supabase 邮件、密码与备份策略。支付二维码应使用受控 HTTPS 图片地址。

## 安全边界

- 金额使用 PostgreSQL `numeric`，不以浮点数存储。
- 匿名用户没有 bookings 表读取策略，只能调用最小化 RPC。
- 预约编号不用于公共鉴权；确认页只接受 256-bit 随机令牌。
- 相机费用 V1 不自动计价；客户不能确认付款或修改价格。
