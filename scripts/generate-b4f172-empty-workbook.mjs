import {mkdir,writeFile} from "node:fs/promises";
import {dirname,resolve} from "node:path";
import * as XLSX from "xlsx";
import {polishMatrixWorkbook} from "../lib/excel-workbook-polish.ts";
import {QUICK_WORKBOOK_SHEETS,QUICK_WORKBOOK_SHEET_ORDER} from "../lib/workbook-contract.ts";

const target=resolve(process.argv[2]??"outputs/b4f172-20260825/szafunek-pusty-szablon-konfiguracji-v2.xlsx");
const workbook=XLSX.utils.book_new();
for(const name of QUICK_WORKBOOK_SHEET_ORDER){
  if(name==="Opis pól"||name==="_LISTY")continue;
  if(name==="Instrukcja"){
    XLSX.utils.book_append_sheet(workbook,XLSX.utils.aoa_to_sheet([["SZAFUNEK — pusta konfiguracja firmy"]]),name);
    continue;
  }
  if(name==="_META"){
    XLSX.utils.book_append_sheet(workbook,XLSX.utils.aoa_to_sheet([["Klucz","Wartość"],["workbookMode","EMPTY_TEMPLATE"],["contractVersion","2"]]),name);
    continue;
  }
  const headers=[...QUICK_WORKBOOK_SHEETS[name].headers];
  const rows=name==="Firma"?[["PLN","Europe/Warsaw",11,1,"TAK"]]:[];
  XLSX.utils.book_append_sheet(workbook,XLSX.utils.aoa_to_sheet([headers,...rows]),name);
}
const raw=XLSX.write(workbook,{type:"array",bookType:"xlsx"});
const bytes=await polishMatrixWorkbook(raw,"QUICK",{mode:"EMPTY_TEMPLATE"});
await mkdir(dirname(target),{recursive:true});
await writeFile(target,bytes);
process.stdout.write(`${target}\n`);
