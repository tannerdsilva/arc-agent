import Foundation

// MARK: - Scripts

/// The JavaScript runtime for the ARC Agent web UI.
///
/// ~50 lines of vanilla JS. Compiled into the binary as a static string.
/// Inlined in the HTML via `<script>` tag. No external files, no build step.
///
/// ## Capabilities
///
/// - **WebSocket connection** — connects to `/ui/ws`, handles reconnection
/// - **Streaming token display** — appends tokens to the last streaming message
/// - **Complete message display** — appends pre-rendered HTML for complete messages
/// - **Auto-scroll** — scrolls to bottom on new content
/// - **Connection status** — updates the `#conn` element on connect/disconnect
/// - **Enter-to-send** — captures Enter key, sends message via WebSocket
///
/// ## What is NOT here (server-side in Swift)
///
/// - Markdown rendering — handled by `markdownToHTML()` in Swift
/// - Syntax highlighting — handled by `highlightCode()` in Swift
/// - State management — all state lives in Swift actors
///
/// ## Design
///
/// This is a static asset, not a generated artifact. It is written once
/// and embedded verbatim. No template functions, no string interpolation,
/// no code generation. Open the file, read the JS.
public enum Scripts {

    /// The complete JavaScript runtime, verbatim.
    ///
    /// Minified for size (~1.2KB). The source is intentionally flat —
    /// no classes, no modules, no build tools. Every browser since 2015
    /// supports everything used here.
    public static let runtime = """
    (function(){
      var ws=new WebSocket('/ui/ws');
      ws.onmessage=function(e){
        var m=JSON.parse(e.data);
        switch(m.type){
          case'token':appendToken(m.text);break;
          case'message':appendMessage(m.html);break;
          case'status':var s=document.getElementById('status');if(s)s.textContent=m.text;break;
        }
      };
      ws.onopen=function(){var c=document.getElementById('conn');if(c){c.className='on';c.textContent='Connected';}};
      ws.onclose=function(){var c=document.getElementById('conn');if(c){c.className='off';c.textContent='Disconnected';}};
      window.__ws=ws;
    })();
    function appendToken(t){
      var c=document.getElementById('messages');
      if(!c)return;
      var l=c.lastElementChild;
      if(!l||!l.classList.contains('streaming')){
        l=document.createElement('div');
        l.className='message-bubble assistant streaming';
        c.appendChild(l);
      }
      l.textContent+=t;
      window.scrollTo(0,document.body.scrollHeight);
    }
    function appendMessage(html){
      var c=document.getElementById('messages');
      if(!c)return;
      var el=document.createElement('div');
      el.className='message-bubble';
      el.innerHTML=html;
      c.appendChild(el);
      window.scrollTo(0,document.body.scrollHeight);
    }
    document.addEventListener('keydown',function(e){
      if(e.key==='Enter'&&!e.shiftKey){
        e.preventDefault();
        var i=document.getElementById('message-input');
        if(i&&i.value.trim()){
          window.__ws.send(JSON.stringify({type:'message',text:i.value}));
          i.value='';
        }
      }
    });
    """
}
