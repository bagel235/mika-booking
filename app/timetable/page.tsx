import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { Timetable } from "./timetable";

export default async function Page() {
  const supabase = createClient(await cookies());
  if (!supabase) redirect("/admin");

  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) redirect("/admin");

  const { data: profile } = await supabase
    .from("profiles")
    .select("id")
    .eq("id", authData.user.id)
    .maybeSingle();
  if (!profile) redirect("/admin");

  return <Timetable />;
}
