import { Confirmation } from "./confirmation";
export default async function Page({params}:{params:Promise<{token:string}>}){return <Confirmation token={(await params).token}/>}
