"use client";

import {
  Bell, Camera, Check, ChevronRight, CircleUserRound, Clock3, Inbox,
  Palette, ShieldCheck, UserRound, X,
} from "lucide-react";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { useAppAuth } from "@/components/AppAuthProvider";
import { APP_COLOR_PALETTE } from "@/lib/app-color-palette";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type PersonalProfile = {
  authUserId:string; displayName:string; avatarMode:"INITIALS"|"CAT"|"PHOTO";
  catAvatarKey?:string|null; noteColor:string; photoPath?:string|null;
  uiPreferences?:Record<string,unknown>;
};
type ProfileWorkspace = {
  profile:PersonalProfile;
  employee?:{id:string;employeeNo:string;firstName:string;lastName:string}|null;
  appRoles?:string[];
};
type PersonalNotification = {
  id:string;kind:string;title:string;body:string;actionRoute?:string|null;
  actionRequired:boolean;readAt?:string|null;resolvedAt?:string|null;createdAt:string;
};
type PersonalRequest = {
  id:string;requestType:"LEAVE"|"SICKNESS"|"HARD_UNAVAILABLE";
  employeeId?:string;employeeName?:string;employeeNo?:string;
  dateFrom:string;dateTo:string;status:string;note?:string|null;
  reviewReason?:string|null;createdAt:string;
};
type ActionWorkspace = {
  unreadCount:number;actionCount:number;notifications:PersonalNotification[];
  managerInbox:PersonalRequest[];myRequests:PersonalRequest[];
};

const EMPTY_ACTIONS:ActionWorkspace={unreadCount:0,actionCount:0,notifications:[],managerInbox:[],myRequests:[]};
const REQUEST_LABELS:Record<string,string>={LEAVE:"Urlop",SICKNESS:"L4",HARD_UNAVAILABLE:"Twarda nieobecność"};
const STATUS_LABELS:Record<string,string>={PENDING:"Czeka na decyzję",APPLIED:"Zapisane — potwierdź odbiór",AUTO_APPLIED:"Zapisane automatycznie",APPROVED:"Zaakceptowane",REJECTED:"Odrzucone",ACKNOWLEDGED:"Przyjęte do wiadomości",CANCELLED:"Anulowane"};
const ROLE_LABELS:Record<string,string>={OWNER:"Właściciel",ADMIN:"Administrator",HR_FINANCE:"Kadry i finanse",ROLE_MANAGER:"Menadżer roli",LOCATION_MANAGER:"Menadżer lokalu",VERIFIER:"Weryfikator",EMPLOYEE:"Pracownik"};

function personalError(message:string){
  const map:Record<string,string>={
    AUTH_REQUIRED:"Zaloguj się ponownie.",FORBIDDEN:"Nie masz uprawnień do tej operacji.",
    EMPLOYEE_PROFILE_REQUIRED:"To konto nie jest jeszcze powiązane z aktywnym profilem pracownika.",
    INVALID_DISPLAY_NAME:"Nazwa wyświetlana musi mieć od 1 do 80 znaków.",
    INVALID_CAT_AVATAR:"Wybierz jednego z dostępnych kotów.",
    INVALID_PROFILE_PHOTO_PATH:"Zdjęcie musi najpierw zostać bezpiecznie przesłane z Twojego konta.",
    SICKNESS_CANNOT_BE_REJECTED:"L4 jest zgłoszeniem faktu i nie można go odrzucić.",
    REVIEW_REASON_REQUIRED:"Przy odrzuceniu wpisz krótkie uzasadnienie.",
  };
  const code=Object.keys(map).find(key=>message.includes(key));
  return code?map[code]:message;
}

function catSprite(key?:string|null):CSSProperties{
  const number=Math.min(55,Math.max(1,Number(key?.replace("CAT_","")||1)));
  const first=number<=25,second=number<=50;
  const local=first?number-1:second?number-26:number-51;
  const columns=second?5:3,rows=second?5:3;
  const column=local%columns,row=Math.floor(local/columns);
  return {
    backgroundImage:`url(${first?"/profile-cats/cats-01-25-v3.png":second?"/profile-cats/cats-26-50-v3.png":"/profile-cats/cats-51-55-v1.png"})`,
    backgroundSize:`${columns*100}% ${rows*100}%`,
    backgroundPosition:`${column/(columns-1)*100}% ${row/(rows-1)*100}%`,
  };
}

export function PersonalAvatar({profile,photoUrl,size="normal"}:{profile:PersonalProfile;photoUrl?:string|null;size?:"small"|"normal"|"large"}){
  const initials=profile.displayName.split(/\s+/).slice(0,2).map(part=>part[0]).join("").toLocaleUpperCase("pl-PL")||"SZ";
  if(profile.avatarMode==="PHOTO"&&photoUrl)return <span className={`personal-avatar ${size}`}><img src={photoUrl} alt="Twoje zdjęcie profilowe"/></span>;
  if(profile.avatarMode==="CAT")return <span className={`personal-avatar cat ${size}`} style={catSprite(profile.catAvatarKey)} aria-label={`Kot ${profile.catAvatarKey?.replace("CAT_","")||"1"}`}/>;
  return <span className={`personal-avatar initials ${size}`}>{initials}</span>;
}

function usePersonalProfile(){
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [workspace,setWorkspace]=useState<ProfileWorkspace|null>(null);
  const [photoUrl,setPhotoUrl]=useState<string|null>(null);
  const [error,setError]=useState("");
  const load=useCallback(async()=>{
    if(!supabase)return;
    const result=await supabase.rpc("personal_profile_workspace_uat_v1");
    if(result.error){setError(personalError(result.error.message));return;}
    const next=result.data as ProfileWorkspace;setWorkspace(next);setError("");
    const path=next.profile?.photoPath;
    if(path){
      const signed=await supabase.storage.from("profile-avatars").createSignedUrl(path,3600);
      setPhotoUrl(signed.data?.signedUrl??null);
    }else setPhotoUrl(null);
  },[supabase]);
  useEffect(()=>{void load();},[load]);
  return {supabase,workspace,setWorkspace,photoUrl,setPhotoUrl,error,load};
}

function usePersonalActions(){
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [workspace,setWorkspace]=useState<ActionWorkspace>(EMPTY_ACTIONS);
  const [error,setError]=useState("");
  const load=useCallback(async()=>{
    if(!supabase)return;
    const result=await supabase.rpc("personal_action_workspace_uat_v1");
    if(result.error){setError(personalError(result.error.message));return;}
    setWorkspace(result.data as ActionWorkspace);setError("");
  },[supabase]);
  useEffect(()=>{void load();},[load]);
  return {supabase,workspace,error,load};
}

export function PersonalHomeGreeting({fallbackName}:{fallbackName?:string}){
  const {workspace,photoUrl}=usePersonalProfile();
  const profile=workspace?.profile;
  return <span className="personal-home-greeting">
    {profile&&<PersonalAvatar profile={profile} photoUrl={photoUrl} size="normal"/>}
    <span><h2>Cześć{profile?.displayName?`, ${profile.displayName}`:fallbackName?`, ${fallbackName}`:""}</h2><p>Najbliższa opublikowana zmiana i sprawy, które wymagają Twojej reakcji.</p></span>
  </span>;
}

export function PersonalActionNote({compact=false}:{compact?:boolean}){
  const router=useRouter();
  const {workspace:profileWorkspace,photoUrl}=usePersonalProfile();
  const {supabase,workspace,error,load}=usePersonalActions();
  const profile=profileWorkspace?.profile;
  const active=workspace.notifications.filter(item=>!item.resolvedAt&&(!item.readAt||item.actionRequired)).slice(0,compact?2:5);
  const open=async(item?:PersonalNotification)=>{
    if(item&&!item.readAt&&supabase){await supabase.rpc("personal_notification_mark_read_uat_v1",{p_notification_id:item.id});await load();}
    router.push(item?.actionRoute||"/profile");
  };
  return <section className={`personal-action-note ${compact?"compact":""}`} style={{"--note-color":profile?.noteColor||"#E8E1D6"} as CSSProperties} aria-label="Do ogarnięcia — powiadomienia i akcje">
    <header>{profile&&<PersonalAvatar profile={profile} photoUrl={photoUrl} size="small"/>}<span><small>DO OGARNIĘCIA</small><h3>{workspace.actionCount?`${workspace.actionCount} ${workspace.actionCount===1?"sprawa wymaga":"sprawy wymagają"} działania`:workspace.unreadCount===1?"1 nowa wiadomość":workspace.unreadCount?`${workspace.unreadCount} nowych wiadomości`:"Wszystko ogarnięte"}</h3></span><Bell/></header>
    {error?<p className="personal-inline-error">{error}</p>:<div className="personal-note-items">{active.map(item=><button type="button" key={item.id} onClick={()=>void open(item)}><span>{item.actionRequired?<ShieldCheck/>:<Bell/>}<b>{item.title}</b><small>{item.body}</small></span><ChevronRight/></button>)}{!active.length&&<p>Nie masz nowych spraw wymagających reakcji.</p>}</div>}
    <button type="button" className="personal-note-open" onClick={()=>void open()}>Otwórz centrum i mój profil <ChevronRight/></button>
  </section>;
}

export function UniversalPersonalWorkspace({management}:{management:boolean}){
  const router=useRouter();
  const {user}=useAppAuth();
  const profileState=usePersonalProfile();
  const actionState=usePersonalActions();
  const {supabase,workspace,photoUrl,setPhotoUrl,error,load}=profileState;
  const profile=workspace?.profile;
  const [displayName,setDisplayName]=useState("");
  const [avatarMode,setAvatarMode]=useState<PersonalProfile["avatarMode"]>("INITIALS");
  const [catKey,setCatKey]=useState("CAT_01");
  const [noteColor,setNoteColor]=useState("#E8E1D6");
  const [photoPath,setPhotoPath]=useState<string|null>(null);
  const [busy,setBusy]=useState(false);
  const [notice,setNotice]=useState("");
  const [reasons,setReasons]=useState<Record<string,string>>({});
  const fileRef=useRef<HTMLInputElement|null>(null);
  useEffect(()=>{if(!profile)return;setDisplayName(profile.displayName);setAvatarMode(profile.avatarMode);setCatKey(profile.catAvatarKey||"CAT_01");setNoteColor(profile.noteColor);setPhotoPath(profile.photoPath||null);},[profile]);
  const draftProfile:PersonalProfile=profile?{...profile,displayName:displayName||profile.displayName,avatarMode,catAvatarKey:avatarMode==="CAT"?catKey:null,noteColor,photoPath:avatarMode==="PHOTO"?photoPath:null}:{authUserId:"",displayName:displayName||"SZ",avatarMode,catAvatarKey:catKey,noteColor,photoPath};
  const save=async()=>{
    if(!supabase)return;setBusy(true);setNotice("");
    const result=await supabase.rpc("personal_profile_save_uat_v1",{
      p_display_name:displayName,p_avatar_mode:avatarMode,
      p_cat_avatar_key:avatarMode==="CAT"?catKey:null,p_note_color:noteColor,
      p_photo_path:avatarMode==="PHOTO"?photoPath:null,p_ui_preferences:profile?.uiPreferences||{},
    });
    setBusy(false);if(result.error){setNotice(personalError(result.error.message));return;}
    setNotice("Profil zapisany. Zmiana jest widoczna od razu.");await load();
  };
  const upload=async(file?:File)=>{
    if(!file||!supabase||!user)return;
    if(file.size>5*1024*1024){setNotice("Zdjęcie może mieć maksymalnie 5 MB.");return;}
    if(!["image/jpeg","image/png","image/webp"].includes(file.type)){setNotice("Wybierz plik JPG, PNG albo WEBP.");return;}
    setBusy(true);setNotice("");
    const extension=file.name.split(".").pop()?.replace(/[^a-z0-9]/gi,"").toLowerCase()||"jpg";
    const path=`${user.id}/${Date.now()}.${extension}`;
    const result=await supabase.storage.from("profile-avatars").upload(path,file,{upsert:false,contentType:file.type});
    if(result.error){setBusy(false);setNotice(personalError(result.error.message));return;}
    const signed=await supabase.storage.from("profile-avatars").createSignedUrl(path,3600);
    setPhotoPath(path);setPhotoUrl(signed.data?.signedUrl??null);setAvatarMode("PHOTO");setBusy(false);
    setNotice("Zdjęcie przesłane. Kliknij „Zapisz profil”, aby je ustawić.");
  };
  const review=async(request:PersonalRequest,decision:"APPROVE"|"REJECT"|"ACKNOWLEDGE")=>{
    if(!actionState.supabase)return;setBusy(true);setNotice("");
    const result=await actionState.supabase.rpc("employee_request_review_uat_v1",{p_request_id:request.id,p_decision:decision,p_reason:reasons[request.id]||null});
    setBusy(false);if(result.error){setNotice(personalError(result.error.message));return;}
    setNotice(decision==="ACKNOWLEDGE"?"L4 przyjęte do wiadomości.":decision==="APPROVE"?"Nieobecność zaakceptowana.":"Wniosek odrzucony.");await actionState.load();
  };
  const openNotification=async(item:PersonalNotification)=>{
    if(!item.readAt&&actionState.supabase){
      await actionState.supabase.rpc("personal_notification_mark_read_uat_v1",{p_notification_id:item.id});
      await actionState.load();
    }
    if(item.actionRoute)router.push(item.actionRoute);
  };
  if(!profile)return <section className="personal-workspace"><div className="engine-loading"><CircleUserRound/><strong>{error||"Pobieram Twój profil…"}</strong></div></section>;
  return <section className="personal-workspace">
    <header className="personal-workspace-hero"><PersonalAvatar profile={draftProfile} photoUrl={photoUrl} size="large"/><span><small>MÓJ OSOBISTY PROFIL</small><h2>{displayName}</h2><p>{workspace?.appRoles?.map(role=>ROLE_LABELS[role]||role).join(" • ")||"Konto aplikacji"}{workspace?.employee?` • ${workspace.employee.employeeNo}`:" • profil niezależny od kartoteki pracownika"}</p></span></header>
    {notice&&<div className="personal-notice" role="status"><Check/>{notice}<button aria-label="Zamknij" onClick={()=>setNotice("")}><X/></button></div>}
    <div className="personal-workspace-grid">
      <section className="personal-profile-editor"><header><UserRound/><span><h3>Jak widzą Cię inni</h3><p>Zdjęcie lub wybrany kot pojawi się przy Twoim imieniu i na karteczce Home.</p></span></header>
        <label>Nazwa wyświetlana<input maxLength={80} value={displayName} onChange={event=>setDisplayName(event.target.value)}/></label>
        <div className="personal-avatar-modes"><button className={avatarMode==="INITIALS"?"active":""} onClick={()=>setAvatarMode("INITIALS")}><CircleUserRound/> Inicjały</button><button className={avatarMode==="CAT"?"active":""} onClick={()=>setAvatarMode("CAT")}><span className="mini-cat" style={catSprite(catKey)}/> Kot</button><button className={avatarMode==="PHOTO"?"active":""} onClick={()=>fileRef.current?.click()}><Camera/> Zdjęcie</button><input ref={fileRef} hidden type="file" accept="image/jpeg,image/png,image/webp" onChange={event=>void upload(event.target.files?.[0])}/></div>
        {avatarMode==="CAT"&&<div className="cat-selector" aria-label="Wybierz kota">{Array.from({length:55},(_,index)=>{const key=`CAT_${String(index+1).padStart(2,"0")}`;return <button type="button" aria-label={`Kot ${index+1}`} aria-pressed={catKey===key} className={catKey===key?"active":""} onClick={()=>setCatKey(key)} key={key}><span style={catSprite(key)}/><small>{index+1}</small></button>;})}</div>}
        <fieldset className="personal-note-colors"><legend><Palette/> Kolor Twojej karteczki</legend>{APP_COLOR_PALETTE.map(color=><button type="button" title={`${color.name} ${color.hex}`} aria-label={`${color.name} ${color.hex}`} aria-pressed={noteColor===color.hex} className={noteColor===color.hex?"active":""} style={{background:color.hex}} onClick={()=>setNoteColor(color.hex)} key={color.hex}/>)}</fieldset>
        <button className="primary-button personal-save" disabled={busy||!displayName.trim()||avatarMode==="PHOTO"&&!photoPath} onClick={()=>void save()}>{busy?"Zapisuję…":"Zapisz profil"}</button>
      </section>
      <section className="personal-notification-centre"><header><Bell/><span><h3>Powiadomienia i akcje</h3><p>Nieprzeczytane wiadomości i sprawy wymagające działania są rozdzielone.</p></span><b>{actionState.workspace.actionCount} akcji • {actionState.workspace.unreadCount} nowych</b></header>
        <div className="personal-notification-list">{actionState.workspace.notifications.map(item=><article className={`${item.actionRequired&&!item.resolvedAt?"action":""} ${!item.readAt?"unread":""}`} key={item.id}><span>{item.actionRequired?<ShieldCheck/>:<Bell/>}<b>{item.title}</b><small>{item.body}</small></span>{item.actionRoute&&<button type="button" onClick={()=>void openNotification(item)}>Otwórz <ChevronRight/></button>}</article>)}{!actionState.workspace.notifications.length&&<p>Nie masz jeszcze powiadomień.</p>}</div>
      </section>
    </div>
    {management&&<section className="personal-manager-inbox"><header><Inbox/><span><small>SKRZYNKA LIDERA</small><h3>Nieobecności wymagające reakcji</h3><p>Urlop i przekroczenie limitu wymagają decyzji. L4 można wyłącznie przyjąć do wiadomości.</p></span><b>{actionState.workspace.managerInbox.length}</b></header><div>{actionState.workspace.managerInbox.map(request=><article key={request.id}><span><small>{REQUEST_LABELS[request.requestType]}</small><b>{request.employeeName} • {request.employeeNo}</b><p>{request.dateFrom}{request.dateTo!==request.dateFrom?` – ${request.dateTo}`:""}{request.note?` • ${request.note}`:""}</p></span>{request.requestType==="SICKNESS"?<button disabled={busy} className="primary-button" onClick={()=>void review(request,"ACKNOWLEDGE")}><Check/> Przyjmij do wiadomości</button>:<div className="personal-review-actions"><input value={reasons[request.id]||""} onChange={event=>setReasons(current=>({...current,[request.id]:event.target.value}))} placeholder="Uzasadnienie przy odrzuceniu"/><button disabled={busy} className="secondary-button" onClick={()=>void review(request,"REJECT")}><X/> Odrzuć</button><button disabled={busy} className="primary-button" onClick={()=>void review(request,"APPROVE")}><Check/> Akceptuj</button></div>}</article>)}{!actionState.workspace.managerInbox.length&&<p className="personal-empty"><Check/> Nie ma spraw oczekujących na Twoją decyzję.</p>}</div></section>}
    <section className="personal-my-requests"><header><Clock3/><span><h3>Moje zgłoszenia</h3><p>Status urlopu, L4 i twardych nieobecności.</p></span></header><div>{actionState.workspace.myRequests.map(request=><article key={request.id}><span><b>{REQUEST_LABELS[request.requestType]||request.requestType}</b><small>{request.dateFrom}{request.dateTo!==request.dateFrom?` – ${request.dateTo}`:""}</small></span><strong>{STATUS_LABELS[request.status]||request.status}</strong>{request.reviewReason&&<p>{request.reviewReason}</p>}</article>)}{!actionState.workspace.myRequests.length&&<p>Nie masz jeszcze zgłoszeń nieobecności.</p>}</div></section>
  </section>;
}
