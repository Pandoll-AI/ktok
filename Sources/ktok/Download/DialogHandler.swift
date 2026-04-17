import Foundation

/// After pressing Save, KakaoTalk may open a sheet-style dialog.
///
/// Classify it by reading every UI element's value, then dismiss with OK/확인.
///  - `friend`   — target is not on the user's friend list
///  - `expired`  — file is permanently deleted / server-expired / save failed
///  - `unknown`  — some other sheet, still dismissed
///  - `none`     — no sheet
enum DialogHandler {
    enum DialogType: String {
        case none
        case friend
        case expired
        case unknown
    }

    static func handle(chat: String) -> DialogType {
        let script = """
        ObjC.import("Foundation");
        var args=ObjC.unwrap($.NSProcessInfo.processInfo.arguments);
        var chatName=ObjC.unwrap(args[args.length-1])||"";
        var se=Application("System Events");
        var kk=se.processes.byName("KakaoTalk");
        var root=null;var wins=kk.windows();
        for(var wi=0;wi<wins.length;wi++){
        try{if(wins[wi].title()===chatName){root=wins[wi];break;}}catch(x){}}
        if(!root)root=wins[0];
        var result={type:"none",text:"",clicked:false};
        try{var sheets=root.sheets();
        if(sheets.length>0){var ch=sheets[0].uiElements();
        var txt="";
        for(var i=0;i<ch.length;i++){
        try{var v=(ch[i].value()||"").toString();if(v)txt+=v+" ";}catch(x){}}
        result.text=txt.substring(0,300);
        if(txt.indexOf("friends list")!==-1||txt.indexOf("친구")!==-1)
        {result.type="friend";}
        else if(txt.indexOf("failed to save")!==-1||txt.indexOf("permanently deleted")!==-1
        ||txt.indexOf("저장에 실패")!==-1
        ||txt.indexOf("영구 삭제")!==-1
        ||txt.indexOf("만료")!==-1
        ||txt.indexOf("expired")!==-1
        ||txt.indexOf("deleted from the server")!==-1)
        {result.type="expired";}
        else{result.type="unknown";}
        for(var i=0;i<ch.length;i++){
        try{var t=ch[i].title();
        if(t==="OK"||t==="확인"){
        ch[i].actions.byName("AXPress").perform();result.clicked=true;break;}
        }catch(x){}}
        }}catch(x){}
        JSON.stringify(result)
        """
        let output = AppleScriptRunner.runJXA(script, argv: [chat], timeoutSec: 8.0)
        guard output.returncode == 0 else { return .none }
        let raw = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let typeString = obj["type"] as? String,
            let dialogType = DialogType(rawValue: typeString)
        else {
            return .none
        }
        return dialogType
    }
}
