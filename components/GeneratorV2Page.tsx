"use client";

import { AlertTriangle, BarChart3, CalendarDays, Check, ChevronRight, Plus, RefreshCw, Sparkles } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SolverV2Panel } from "@/components/SolverV2Panel";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  getSolverRunsCatalog, solverErrorMessage, solverStatusLabel,
  type SolverCatalogRun, type SolverConfiguration,
} from "@/lib/solver-v2";

type Props={
  configuration:SolverConfiguration;userId:string;month:string;timezone:string;
  notify:(message:string)=>void;fail:(message:string)=>void;onPublished:()=>Promise<void>;
};

function timestamp(value:string,timezone:string){
  const date=new Date(value);if(!Number.isFinite(date.getTime()))return "—";
  return new Intl.DateTimeFormat("pl-PL",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit",timeZone:timezone}).format(date);
}
function money(value:number|null|undefined,currency:string){
  if(value===null||value===undefined||!currency)return "—";
  return new Intl.NumberFormat("pl-PL",{style:"currency",currency,maximumFractionDigits:0}).format(value/100);
}

export function GeneratorV2Page({configuration,userId,month,timezone,notify,fail,onPublished}:Props){
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const defaultScenario=configuration.scenarios.find(item=>item.isDefault)??configuration.scenarios[0];
  const [scenarioCode,setScenarioCode]=useState(defaultScenario?.code??"");
  const [name,setName]=useState(`Grafik ${month.slice(0,7)}`);
  const [catalog,setCatalog]=useState<SolverCatalogRun[]>([]);
  const [selectedRunId,setSelectedRunId]=useState<string|null>(null);
  const [loading,setLoading]=useState(false);
  const [refreshKey,setRefreshKey]=useState(0);
  const [skipRecovery,setSkipRecovery]=useState(false);
  const workbenchRef=useRef<HTMLElement|null>(null);

  function startNewGeneration(){
    setSelectedRunId(null);
    setSkipRecovery(true);
    setRefreshKey(value=>value+1);
    window.requestAnimationFrame(()=>window.requestAnimationFrame(()=>{
      workbenchRef.current?.scrollIntoView({behavior:"smooth",block:"start"});
    }));
  }

  const loadCatalog=useCallback(async()=>{
    if(!supabase)return;
    setLoading(true);
    try{setCatalog(await getSolverRunsCatalog(supabase,month,"COMPANY"));}
    catch(error){fail(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLoading(false);}
  },[supabase,month,fail]);
  useEffect(()=>{void loadCatalog();},[loadCatalog,refreshKey]);
  useEffect(()=>{
    const selected=configuration.scenarios.find(item=>item.code===scenarioCode);
    if(!selected)setScenarioCode((configuration.scenarios.find(item=>item.isDefault)??configuration.scenarios[0])?.code??"");
    setSelectedRunId(null);setName(`Grafik ${month.slice(0,7)}`);
  },[month,configuration.scenarios,scenarioCode]);

  return <section className="generator-v2-page">
    <header className="generator-v2-hero">
      <div><p className="eyebrow">GENERATOR I WARIANTY • OR-TOOLS</p><h2>Scenariusze, analizy i wybór wariantu</h2><p>Generowanie tworzy osobne warianty robocze. Dopiero świadomy wybór i publikacja tworzą grafik operacyjny.</p></div>
      <button className="secondary-button" disabled={loading} onClick={()=>void loadCatalog()}><RefreshCw className={loading?"spin":""}/> Odśwież historię</button>
    </header>

    <div className="generator-v2-flow">
      <span className="active"><b>1</b> Scenariusz</span><ChevronRight/><span><b>2</b> Warianty</span><ChevronRight/><span><b>3</b> Analiza i wybór</span><ChevronRight/><span><b>4</b> Publikacja</span>
    </div>

    {configuration.engine==="SHADOW"&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Tryb testowy</strong><small>Możesz generować i porównywać wyniki, ale publikacja pozostaje zablokowana.</small></span></div>}

    <section className="generator-v2-scenarios">
      <div className="section-head"><div><p className="eyebrow">ZAŁOŻENIA WEJŚCIOWE</p><h3>Wybierz scenariusz Matrixa</h3></div><button className="primary-button" onClick={startNewGeneration}><Plus/> Nowe generowanie</button></div>
      <div>{configuration.scenarios.map(scenario=><button className={scenario.code===scenarioCode?"selected":""} key={scenario.id??scenario.code} onClick={()=>{setScenarioCode(scenario.code);setSelectedRunId(null);setSkipRecovery(true);}}><span><Sparkles/><strong>{scenario.name}</strong>{scenario.isDefault&&<em>DOMYŚLNY</em>}</span><p>{scenario.description||"Scenariusz bez dodatkowego opisu."}</p><small>{scenario.strategyCount} {scenario.strategyCount===1?"strategia":"strategie/warianty"}</small></button>)}</div>
    </section>

    <section className="generator-v2-catalog">
      <div className="section-head"><div><p className="eyebrow">HISTORIA MIESIĄCA</p><h3>Wszystkie generowania i warianty</h3></div><span>{catalog.length}</span></div>
      {!catalog.length&&!loading&&<p className="solver-workspace-empty">Nie ma jeszcze generowań dla tego miesiąca.</p>}
      {catalog.map(run=><article className={selectedRunId===run.id?"selected":""} key={run.id}>
        <header><span><CalendarDays/><small>{timestamp(run.createdAt,timezone)}</small><strong>{run.name}</strong></span><em>{solverStatusLabel(run.status)} • {run.progress}%</em></header>
        <p>{run.scenario.name} • {run.variants.length} wariantów</p>
        <div className="generator-v2-catalog-variants">{run.variants.map(variant=><span className={variant.selected?"chosen":""} key={variant.id}><b>{variant.strategy.name}</b><small>{variant.assignmentCount} przydz. • {variant.unfilledCount} braków • {money(variant.totalCostMinor,variant.currency)}</small>{variant.selected&&<em><Check/> wybrany</em>}</span>)}</div>
        <button className="secondary-button" onClick={()=>{setSkipRecovery(false);setSelectedRunId(run.id);}}><BarChart3/> Otwórz analizę i porównanie</button>
      </article>)}
    </section>

    <section className="generator-v2-workbench" ref={workbenchRef}>
      <SolverV2Panel
        key={`${refreshKey}:${selectedRunId??"new"}:${configuration.solverVersion}:${month}:${scenarioCode}`}
        engine={configuration.engine}
        solverVersion={configuration.solverVersion??""}
        userId={userId}
        month={month}
        timezone={timezone}
        name={name}
        scenarioCode={scenarioCode}
        scenarios={configuration.scenarios}
        scopeType="COMPANY"
        scopeRoleId={null}
        scopeLabel="Grafik całej firmy"
        matrixEffectiveFrom={configuration.matrixEffectiveFrom}
        allowStart={Boolean(configuration.solverVersion)}
        initialRunId={selectedRunId}
        skipRecovery={skipRecovery}
        onNameChange={setName}
        onScenarioChange={value=>{setScenarioCode(value);setSelectedRunId(null);}}
        onVariantSelected={async variant=>{notify(`Wybrano wariant: ${variant.strategy.name}`);await loadCatalog();}}
        onPublished={async()=>{await onPublished();await loadCatalog();notify("Wariant został opublikowany jako nowa wersja grafiku operacyjnego.");}}
      />
    </section>
  </section>;
}
