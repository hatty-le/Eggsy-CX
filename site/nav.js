/* Eggsy CX shared left-hand menu. To add a page: add one line to PAGES below and include
   <script src="/nav.js"></script> as the first thing inside <body> on the new page. */
(function(){
var PAGES=[
 {href:'/',label:'Home',icon:'🏠'},
 {href:'/inbox/',label:'Inbox',icon:'💬',count:'inbox'},
 {href:'/waiting/',label:'Waiting',icon:'⏳',count:'waiting'},
 {href:'/resolved/',label:'Resolved',icon:'✅',count:'resolved'},
 {href:'/junk/',label:'Junk',icon:'🗑️',count:'junk'},
 {href:'/actions/',label:'Actions',icon:'📌',count:'actions'},
 {href:'/knowledge/',label:'Knowledge',icon:'📚'},
 {href:'/sent/',label:'Sent log',icon:'📤'},
 {href:'/metrics/',label:'Metrics',icon:'📊'}
];
var css=''+
':root{--nav-w:220px}'+
'.enav{position:fixed;top:0;left:0;bottom:0;width:var(--nav-w);background:#1d1b26;color:#fff;display:flex;flex-direction:column;z-index:50;padding:18px 12px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}'+
'.enav-brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:19px;color:#fff;text-decoration:none;padding:4px 10px 20px}'+
'.enav-egg{width:24px;height:30px;background:#fff;border-radius:50%/60% 60% 40% 40%;position:relative;flex:none}'+
'.enav-egg:after{content:"";position:absolute;width:11px;height:11px;background:#FFC83D;border-radius:50%;left:6.5px;top:13px}'+
'.enav-links{display:flex;flex-direction:column;gap:4px;flex:1;overflow-y:auto}'+
'.enav-links a{display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:12px;color:#e9e6f2;text-decoration:none;font-size:15px;font-weight:600}'+
'.enav-links a:hover{background:rgba(255,255,255,.08)}'+
'.enav-links a.on{background:#FFC83D;color:#1d1b26}'+
'.enav-n{margin-left:auto;min-width:24px;text-align:center;font-size:12px;font-weight:700;border-radius:999px;padding:1px 7px;background:rgba(255,255,255,.14);color:#fff}'+
'.enav-n:empty{display:none}.enav-links a.on .enav-n{background:#1d1b26;color:#fff}'+
'.enav-user{border-top:1px solid rgba(255,255,255,.15);padding:12px 10px 2px;font-size:13px;color:#cfcbe0}'+
'.enav-email{color:#fff;font-weight:600;overflow-wrap:anywhere}'+
'.enav-user button{margin-top:8px;background:transparent;color:#fff;border:1px solid rgba(255,255,255,.35);border-radius:999px;padding:6px 14px;font:inherit;font-weight:600;cursor:pointer}'+
'.enav-top{display:none}'+
'.enav-shade{display:none}'+
'body{padding-left:var(--nav-w)}'+
'@media (max-width:900px){'+
' body{padding-left:0}'+
' .enav{transform:translateX(-105%);transition:transform .2s ease;width:260px;box-shadow:4px 0 24px rgba(0,0,0,.25)}'+
' body.enav-open .enav{transform:none}'+
' body.enav-open .enav-shade{display:block;position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:40}'+
' .enav-top{display:flex;align-items:center;gap:10px;padding:10px 14px;background:#1d1b26;color:#fff;position:sticky;top:0;z-index:30}'+
' .enav-top a{color:#fff;text-decoration:none;font-weight:800;font-size:17px;display:flex;align-items:center;gap:8px}'+
' .enav-burger{background:transparent;border:0;color:#fff;font-size:24px;line-height:1;padding:4px 8px;cursor:pointer}'+
' .enav-here{margin-left:auto;font-size:13px;color:#cfcbe0}'+
'}';
var st=document.createElement('style');st.textContent=css;document.head.appendChild(st);
var path=location.pathname.replace(/index\.html$/,'');if(!/\/$/.test(path))path+='/';
var cur=PAGES.filter(function(p){return p.href===path})[0]||null;
var nav=document.createElement('nav');nav.className='enav';nav.setAttribute('aria-label','Eggsy CX pages');
var brand=document.createElement('a');brand.className='enav-brand';brand.href='/';brand.innerHTML='<span class="enav-egg"></span>Eggsy CX';nav.appendChild(brand);
var links=document.createElement('div');links.className='enav-links';
var badges={};
PAGES.forEach(function(p){var a=document.createElement('a');a.href=p.href;a.textContent=p.icon+'  '+p.label;if(cur===p){a.className='on';a.setAttribute('aria-current','page')}
 if(p.count){var n=document.createElement('span');n.className='enav-n';n.setAttribute('aria-label',p.label+' conversations');badges[p.count]=n;a.appendChild(n)}
 links.appendChild(a)});
nav.appendChild(links);
var user=document.createElement('div');user.className='enav-user';user.style.display='none';nav.appendChild(user);
var shade=document.createElement('div');shade.className='enav-shade';
var top=document.createElement('div');top.className='enav-top';
var burger=document.createElement('button');burger.className='enav-burger';burger.type='button';burger.setAttribute('aria-label','Open menu');burger.textContent='☰';
var tb=document.createElement('a');tb.href='/';tb.innerHTML='<span class="enav-egg"></span>Eggsy CX';
var here=document.createElement('span');here.className='enav-here';here.textContent=cur?cur.label:'';
top.appendChild(burger);top.appendChild(tb);top.appendChild(here);
function close(){document.body.classList.remove('enav-open')}
burger.onclick=function(){document.body.classList.toggle('enav-open')};shade.onclick=close;
document.addEventListener('keydown',function(e){if(e.key==='Escape')close()});
function mount(){var b=document.body;b.insertBefore(shade,b.firstChild);b.insertBefore(nav,b.firstChild);b.insertBefore(top,b.firstChild)}
if(document.body)mount();else document.addEventListener('DOMContentLoaded',mount);
var KEY='eggsy_return';
var countSb=null,countTimer=null;
function setCounts(c){Object.keys(badges).forEach(function(k){badges[k].textContent=(c&&c[k]!=null)?String(c[k]):''})}
// Inbox / Waiting / Resolved counts come from the staff-only cx_bucket_counts() function (RLS applies).
function refreshCounts(){if(!countSb)return Promise.resolve();return countSb.rpc('cx_bucket_counts').then(function(r){if(r&&!r.error)setCounts(r.data)},function(){})}
window.EggsyNav={
 pages:PAGES,
 setCounts:setCounts,
 refreshCounts:refreshCounts,
 setUser:function(email,signOut,sb){user.innerHTML='';
  if(!email){user.style.display='none';countSb=null;setCounts(null);if(countTimer){clearInterval(countTimer);countTimer=null}return}
  if(sb){countSb=sb;refreshCounts();if(!countTimer)countTimer=setInterval(refreshCounts,60000)}
  user.style.display='block';var s=document.createElement('div');s.textContent='Signed in as';var e=document.createElement('div');e.className='enav-email';e.textContent=email;user.appendChild(s);user.appendChild(e);
  if(signOut){var b=document.createElement('button');b.type='button';b.textContent='Sign out';b.onclick=signOut;user.appendChild(b)}},
 // Remember where to come back to after Google sign-in (backup for the redirect URL itself).
 stashReturn:function(p){try{localStorage.setItem(KEY,JSON.stringify({path:p||(location.pathname+location.search),t:Date.now()}))}catch(e){}},
 takeReturn:function(){try{var r=JSON.parse(localStorage.getItem(KEY)||'null');localStorage.removeItem(KEY);
  if(r&&r.path&&Date.now()-r.t<6*3600e3&&/^\/[a-z\/]*(\?c=[0-9a-f-]{36})?$/i.test(r.path))return r.path}catch(e){}return null}
};
// Shared "Log in with Google" helpers (Supabase OAuth, PKCE). Used by /, /inbox/ and /sent/.
var GBTN_CSS='.gbtn{display:inline-flex;align-items:center;justify-content:center;gap:10px;width:100%;background:#fff;color:#1f1f1f;border:1px solid #747775;border-radius:999px;padding:11px 18px;font:600 15px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;cursor:pointer}'+
 '.gbtn:hover{background:#f6f8fc}.gbtn:disabled{opacity:.6;cursor:default}.gbtn svg{width:18px;height:18px;flex:none}';
var gs=document.createElement('style');gs.textContent=GBTN_CSS;document.head.appendChild(gs);
var GLOGO='<svg viewBox="0 0 48 48" aria-hidden="true"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>';
var UUID=/^[0-9a-f-]{36}$/i;
function friendly(err){var m=(err&&err.message||'').toLowerCase();
 if(m.indexOf('provider is not enabled')>=0||m.indexOf('unsupported provider')>=0)return 'Google sign-in is not switched on in Supabase yet. Ask Hatty to finish the Google set-up.';
 if(m.indexOf('verifier')>=0)return 'Sign-in was finished in a different browser from the one it started in. Press "Log in with Google" again here.';
 if(m.indexOf('failed to fetch')>=0||m.indexOf('network')>=0)return 'Could not reach the sign-in service. Check your connection and try again.';
 return 'Sign-in failed: '+(err&&err.message||'unknown error');}
window.EggsyAuth={
 okEmail:function(e){return /@luckyegg\.co$/i.test(e||'')},
 friendly:friendly,
 // Fill a container with the single "Log in with Google" button.
 button:function(host,sb,setMsg,path){host.innerHTML='';var b=document.createElement('button');b.type='button';b.className='gbtn';b.innerHTML=GLOGO+'<span>Log in with Google</span>';
  b.onclick=function(){b.disabled=true;if(setMsg)setMsg('Opening Google…');EggsyAuth.signIn(sb,setMsg,path).then(function(err){if(err){b.disabled=false;if(setMsg)setMsg(friendly(err),true)}})};
  host.appendChild(b);return b},
 // Start Google OAuth and come back to this exact page (keeping ?c=<conversation id>).
 signIn:function(sb,setMsg,path){var c=new URLSearchParams(location.search).get('c');
  path=path||(location.pathname+(c&&UUID.test(c)?'?c='+c:''));
  window.EggsyNav.stashReturn(path);
  return sb.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+path,queryParams:{hd:'luckyegg.co',prompt:'select_account'}}})
   .then(function(r){return r.error||null},function(e){return e})},
 // Finish sign-in when Google/Supabase sends us back (?code= for PKCE, #access_token for older implicit links, or an error), then tidy the URL.
 handleRedirect:function(sb,setMsg){var h=new URLSearchParams(location.hash.replace(/^#/,''));var q=new URLSearchParams(location.search);
  var has=h.has('access_token')||h.has('error')||h.has('error_description')||q.has('code')||q.has('error')||q.has('error_description');
  if(!has)return Promise.resolve();
  var clean=function(){var keep=q.get('c');history.replaceState(null,'',location.pathname+(keep&&UUID.test(keep)?'?c='+keep:''))};
  var errDesc=h.get('error_description')||q.get('error_description')||h.get('error')||q.get('error');
  if(errDesc){var code=(h.get('error')||q.get('error')||'');
   setMsg(code==='access_denied'?'Google sign-in was cancelled. Press "Log in with Google" to try again.':'Sign-in failed: '+errDesc.replace(/\+/g,' '),true);clean();return Promise.resolve()}
  setMsg('Signing you in…');
  var p=h.has('access_token')?sb.auth.setSession({access_token:h.get('access_token'),refresh_token:h.get('refresh_token')||''}):sb.auth.exchangeCodeForSession(q.get('code'));
  return p.then(function(r){if(r&&r.error)setMsg(friendly(r.error),true);else setMsg('')},function(e){setMsg(friendly(e),true)}).then(clean)},
 // Someone signed in with a Google account outside luckyegg.co: sign them straight out and say why.
 reject:function(sb,email,setMsg){return sb.auth.signOut().then(function(){setMsg('You signed in as '+email+', which is not an @luckyegg.co Google account, so you have been signed out. Press "Log in with Google" and pick your @luckyegg.co account.',true)})}
};
})();
