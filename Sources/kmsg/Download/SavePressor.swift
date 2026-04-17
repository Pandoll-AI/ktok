import Foundation

/// Presses the "Save" / "Save As" (저장 / 다른 이름으로 저장) button inside a
/// KakaoTalk file-bubble row.
///
/// Two code paths, both via JXA (osascript -l JavaScript):
///
///  - **row_index ≥ 0** (fast, ~2 s): access the row by index, scan its cell
///    children for an `AXButton` whose description is one of the save markers,
///    and invoke `AXPress`.
///  - **scan fallback** (slow, ~30 s): no row index — iterate every row from
///    newest to oldest, match by `target_value`, then press.
///
/// Preferring "Save" over "Save As" keeps the download silent (no Save panel)
/// when that is possible.
enum SavePressor {
    struct Outcome {
        let pressed: Bool
        let debug: String
    }

    static func press(chat: String, targetValue: String, rowIndex: Int = -1) -> Outcome {
        if rowIndex >= 0 {
            let script = """
            ObjC.import("Foundation");
            var args=ObjC.unwrap($.NSProcessInfo.processInfo.arguments);
            var chatName=ObjC.unwrap(args[args.length-2])||"";
            var rowIdx=parseInt(ObjC.unwrap(args[args.length-1])||"0",10);
            var se=Application("System Events");
            var kk=se.processes.byName("KakaoTalk");
            var root=null;var wins=kk.windows();
            for(var wi=0;wi<wins.length;wi++){
            try{if(wins[wi].title()===chatName){root=wins[wi];break;}}catch(x){}}
            if(!root)root=wins[0];
            var tbl=null;var topEls=root.uiElements();
            for(var ti=0;ti<topEls.length;ti++){
            try{if(topEls[ti].role()==="AXScrollArea"){
            var t0=topEls[ti].uiElements[0];
            if(t0.role()==="AXTable"){tbl=t0;break;}
            }}catch(x){}}
            var result={found:false,btn:"",btns:[]};
            if(tbl){try{
            var row=tbl.uiElements[rowIdx];
            var cell=row.uiElements[0];
            var ch=cell.uiElements();
            var saveBtn=null,saveAsBtn=null;
            for(var i=0;i<ch.length;i++){
            var crl="";try{crl=ch[i].role();}catch(x){}
            var ds="";try{ds=(ch[i].description()||"").toString();}catch(x){}
            if(crl==="AXButton"){
            result.btns.push(ds);
            if(ds==="Save"||ds==="저장")saveBtn=ch[i];
            if(ds==="Save As"||ds==="다른 이름으로")saveAsBtn=ch[i];
            }}
            var btn=saveBtn||saveAsBtn;
            if(btn){try{btn.actions.byName("AXPress").perform();
            result.found=true;result.btn=saveBtn?"Save":"SaveAs";}catch(x){result.err=""+x;}}
            else{result.err="no save button in row "+rowIdx;}
            }catch(x){result.err="row access:"+x;}}
            JSON.stringify(result)
            """
            return execute(script: script, argv: [chat, String(rowIndex)], timeoutSec: 15.0)
        }

        // Fallback: full scan by value — slow, used only when row_index is unknown.
        let script = """
        ObjC.import("Foundation");
        var args=ObjC.unwrap($.NSProcessInfo.processInfo.arguments);
        var chatName=ObjC.unwrap(args[args.length-2])||"";
        var targetVal=ObjC.unwrap(args[args.length-1])||"";
        var se=Application("System Events");
        var kk=se.processes.byName("KakaoTalk");
        var root=null;var wins=kk.windows();
        for(var wi=0;wi<wins.length;wi++){
        try{if(wins[wi].title()===chatName){root=wins[wi];break;}}catch(x){}}
        if(!root)root=wins[0];
        var tbl=null;var topEls=root.uiElements();
        for(var ti=0;ti<topEls.length;ti++){
        try{if(topEls[ti].role()==="AXScrollArea"){
        var t0=topEls[ti].uiElements[0];
        if(t0.role()==="AXTable"){tbl=t0;break;}
        }}catch(x){}}
        var result={found:false,btn:"",btns:[]};
        if(tbl){var rows=tbl.uiElements();
        for(var ri=rows.length-1;ri>=0&&!result.found;ri--){
        try{if(rows[ri].role()!=="AXRow")continue;
        var cell=rows[ri].uiElements[0];
        var ch=cell.uiElements();
        var hasFile=false,saveBtn=null,saveAsBtn=null;
        for(var i=0;i<ch.length;i++){
        var v="";try{v=(ch[i].value()||"").toString();}catch(x){}
        var crl="";try{crl=ch[i].role();}catch(x){}
        var ds="";try{ds=(ch[i].description()||"").toString();}catch(x){}
        if(targetVal&&v.indexOf(targetVal)!==-1)hasFile=true;
        if(crl==="AXButton"){
        result.btns.push(ds);
        if(ds==="Save"||ds==="저장")saveBtn=ch[i];
        if(ds==="Save As"||ds==="다른 이름으로")saveAsBtn=ch[i];
        }}
        if(hasFile){
        var btn=saveBtn||saveAsBtn;
        if(btn){try{btn.actions.byName("AXPress").perform();
        result.found=true;result.btn=saveBtn?"Save":"SaveAs";}catch(x){result.err=""+x;}}
        else{result.err="no save button";}}
        }catch(x){}}}
        JSON.stringify(result)
        """
        return execute(script: script, argv: [chat, targetValue], timeoutSec: 20.0)
    }

    private static func execute(script: String, argv: [String], timeoutSec: TimeInterval) -> Outcome {
        let output = AppleScriptRunner.runJXA(script, argv: argv, timeoutSec: timeoutSec)
        if output.returncode == 0 {
            let raw = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let pressed = obj["found"] as? Bool ?? false
                return Outcome(pressed: pressed, debug: raw)
            }
            let trimmed = raw.count > 120 ? String(raw.prefix(120)) : raw
            return Outcome(pressed: false, debug: "json_error:\(trimmed)")
        }
        let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = err.count > 200 ? String(err.prefix(200)) : err
        return Outcome(pressed: false, debug: "jxa_rc=\(output.returncode) err=\(short)")
    }
}
