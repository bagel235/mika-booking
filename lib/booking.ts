export const bookingTypes = ["SINGLE", "DOUBLE", "TRIPLE", "PRIVATE"] as const;
export type BookingType = (typeof bookingTypes)[number];
export const typeLabels: Record<BookingType, string> = { SINGLE: "单人", DOUBLE: "双人", TRIPLE: "三人", PRIVATE: "包场" };
export const statusLabels: Record<string, string> = { HOLD:"等待定金确认", CONFIRMED:"预约成功", COMPLETED:"预约已完成", CANCELLED:"预约已取消", EXPIRED:"锁定已过期", RESCHEDULED:"预约已改期" };
export const sourceLabels: Record<string, string> = { CUSTOMER_WEB:"客户自助预约", STAFF_MANUAL:"店员登记" };
export const money = (v: number|string) => `¥${Number(v).toFixed(2)}`;
export const timeEnd = (start: string, duration: number) => `${String(Number(start.slice(0,2))+duration).padStart(2,"0")}:00`;
