# Claude — CLI Reference
# Source: https://code.claude.com/docs/en/overview
# Fetched: 2026-05-09 02:17 JST

Claude Code overview - Claude Code Docs!function(){var b="/docs";
function a(p){if(p==null)return"/";p=""+p;if(""===p)return"/";return"/"===p.charAt(0)?p:"/"+p}
function u(p){if(p==null)return p;p=""+p;if(!p||p.charAt(p.length-1)==="/")return p.slice(0,-1);return p}
function i(p){if(p==null)return p;p=""+p;if(6<=p.length&&p.substring(p.length-6)==="/index")return p.substring(0,p.length-6);if("index"===p)return"";return p}
var p=(location.pathname||"").split("?")[0].split("#")[0]||"";
if(b)if(p===b)p="";else if(0===p.indexOf(b+"/"))p=p.substring(b.length);
p=a(p);p=u(p);p=i(p);p=""===p||"index"===p?"/":a(p);
document.documentElement.setAttribute("data-current-path",p);
}();(function(a,b){try{let c=document.getElementById("banner")?.innerText;if(c){for(let d=0;d<localStorage.length;d++){let e=localStorage.key(d);if(e?.endsWith(a)&&localStorage.getItem(e)===c)return void document.documentElement.setAttribute(b,"hidden")}document.documentElement.setAttribute(b,"visible");return}for(let c=0;c<localStorage.length;c++){let d=localStorage.key(c);if(d?.endsWith(a)&&localStorage.getItem(d))return void document.documentElement.setAttribute(b,"hidden")}document.documentElement.setAttribute(b,"visible")}catch(a){document.documentElement.setAttribute(b,"hidden")}})(
 "bannerDismissed",
 "data-banner-state",
)((a,b,c,d,e,f,g,h)=>{let i=document.documentElement,j=["light","dark"];function k(b){var c;(Array.isArray(a)?a:[a]).forEach(a=>{let c="class"===a,d=c&&f?e.map(a=>f[a]||a):e;c?(i.classList.remove(...d),i.classList.add(f&&f[b]?f[b]:b)):i.setAttribute(a,b)}),c=b,h&&j.includes(c)&&(i.style.colorScheme=c)}if(d)k(d);else try{let a=localStorage.getItem(b)||c,d=g&&"system"===a?window.matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light":a;k(d)}catch(a){}})("class","isDarkMode","system",null,["dark","light","true","false","system"],{"true":"dark","false":"light","dark":"dark","light":"light"},true,false):root{--banner-height:0px!important}(self.__next_s=self.__next_s||[]).push([0,{"children":"(function g(a,b,c,d,e){try{let f,g,h=[];try{h=window.location.pathname.split(\"/\").filter(a=\u003e\"\"!==a\u0026\u0026\"global\"!==a).slice(0,2)}catch{h=[]}let i=h.find(a=\u003ec.includes(a)),j=[];for(let c of(i?j.push(i):j.push(b),j.push(\"global\"),j)){if(!c)continue;let b=a[c];if(b?.content){f=b.content,g=c;break}}if(!f)return void document.documentElement.setAttribute(d,\"hidden\");let k=!0,l=0;for(;l\u003clocalStorage.length;){let a=localStorage.key(l);if(l++,!a?.endsWith(e))continue;let b=localStorage.getItem(a);if(b\u0026\u0026b===f){k=!1;break}g\u0026\u0026(a.startsWith(`lang:${g}_`)||!a.startsWith(\"lang:\"))\u0026\u0026(localStorage.removeItem(a),l--)}document.documentElement.setAttribute(d,k?\"visible\":\"hidden\")}catch(a){console.error(a),document.documentElement.setAttribute(d,\"hidden\")}})(\n {},\n \"en\",\n [\"en\",\"fr\",\"de\",\"it\",\"jp\",\"es\",\"ko\",\"cn\",\"zh-Hant\",\"ru\",\"id\",\"pt-BR\"],\n \"data-banner-state\",\n \"bannerDismissed\",\n)","id":"_mintlify-banner-script"}]):root {
 --font-family-headings-custom: "Anthropic Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
 --font-family-body-custom: "Anthropic Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
}
:root {
 --primary: 14 14 14;
 --primary-light: 212 162 127;
 --primary-dark: 14 14 14;
 --tooltip-foreground: 255 255 255;
 --background-light: 253 253 247;
 --background-dark: 9 9 11;
 --gray-50: 243 243 243;
 --gray-100: 238 238 238;
 --gray-200: 222 222 222;
 --gray-300: 206 206 206;
 --gray-400: 158 158 158;
 --gray-500: 112 112 112;
 --gray-600: 80 80 80;
 --gray-700: 62 62 62;
 --gray-800: 37 37 37;
 --gray-900: 23 23 23;
 --gray-950: 10 10 10;
 }
 (function() {
 function loadKatex() {
 const link = document.querySelector('link[href="https://d4tuoctqmanu0.cloudfront.net/katex.min.css"]');
 if (link) link.rel = 'stylesheet';
 }
 if (document.readyState === 'loading') {
 document.addEventListener('DOMContentLoaded', loadKatex);
 } else {
 loadKatex();
 }
 })();
 (self.__next_s=self.__next_s||[]).push([0,{"suppressHydrationWarning":true,"children":"(function(a,b,c,d){var e;let f,g,h=\"mint\"===d||\"linden\"===d?\"sidebar\":\"sidebar-content\",i=(e=d,f=\"navbar-transition\",\"maple\"===e\u0026\u0026(f+=\"-maple\"),f),[j,k]=(()=\u003e{switch(d){case\"almond\":return[\"[--scroll-mt:2.5rem]\",\"[--scroll-mt:2.5rem]\"];case\"luma\":return[\"lg:[--scroll-mt:6rem]\",\"lg:[--scroll-mt:6rem]\"];case\"sequoia\":return[\"lg:[--scroll-mt:8.5rem]\",\"lg:[--scroll-mt:11rem]\"];default:return[\"lg:[--scroll-mt:9.5rem]\",\"lg:[--scroll-mt:12rem]\"]}})();function l(){document.documentElement.classList.add(j)}let m=document.documentElement.getAttribute(\"data-banner-state\"),n=null!=m?\"visible\"===m:b;function o(a){let b=n?`calc(${a-2.5}rem + var(--banner-height, 2.5rem))`:`${a}rem`;document.getElementById(h)?.style.setProperty(\"top\",b)}function p(a){let b=n?`calc(100vh - ${a-2.5}rem - var(--banner-height, 2.5rem))`:`calc(100vh - ${a}rem)`;document.getElementById(h)?.style.setProperty(\"height\",b)}function q(a,b){!a\u0026\u0026b||a\u0026\u0026!b?(l(),document.documentElement.classList.remove(k)):a\u0026\u0026b\u0026\u0026(document.documentElement.classList.add(k),document.documentElement.classList.remove(j))}switch(d){case\"mint\":o(c),q(a,n);break;case\"palm\":case\"aspen\":case\"sequoia\":o(c),p(c),q(a,n);break;case\"luma\":l();break;case\"linden\":o(c),n\u0026\u0026l();break;case\"almond\":l(),o(c),p(c)}let r=((g=document.createElement(\"style\")).appendChild(document.createTextNode(\"*,*::before,*::after{-webkit-transition:none!important;-moz-transition:none!important;-o-transition:none!important;-ms-transition:none!important;transition:none!important}\")),document.head.appendChild(g),function(){window.getComputedStyle(document.body),setTimeout(()=\u003e{document.head.removeChild(g)},1)});(\"requestAnimationFrame\"in globalThis?requestAnimationFrame:setTimeout)(()=\u003e{let a;a=!1,a=window.scrollY\u003e50,document.getElementById(i)?.setAttribute(\"data-is-opaque\",`${!!a}`),r()})})(\n true,\n false,\n (function l(a,b,c){let d=document.documentElement.getAttribute(\"data-banner-state\"),e=2.5*!!(null!=d?\"visible\"===d:b),f=3*!!a,g=4,h=e+g+f;switch(c){case\"mint\":case\"palm\":break;case\"aspen\":f=2.5*!!a,g=3.5,h=e+f+g;break;case\"luma\":g=3,h=e+g;break;case\"linden\":g=4,h=e+g;break;case\"almond\":g=3.5,h=e+g;break;case\"sequoia\":f=3*!!a,g=3,h=e+g+f}return h})(true, false, \"mint\"),\n \"mint\",\n)","id":"_mintlify-scroll-top-script"}])Skip to main content(function h(a,b,c,d){try{if(window.matchMedia("(max-width: 1024px)").matches||!d){document.documentElement.style.setProperty(c,"0px"),document.documentElement.setAttribute("data-assistant-state","closed"),d||localStorage.setItem(a,"false");return}let e=localStorage.getItem(a);if(null===e){document.documentElement.style.setProperty(c,"0px"),document.documentElement.setAttribute("data-assistant-state","closed");return}let f=JSON.parse(e),g=localStorage.getItem(b),h=null!==g?JSON.parse(g):368;document.documentElement.style.setProperty(c,f?h+"px":"0px"),document.documentElement.setAttribute("data-assistant-state",f?"open":"closed")}catch(a){document.documentElement.style.setProperty(c,"0px"),document.documentElement.setAttribute("data-assistant-state","closed")}})(
 "chat-assistant-sheet-open",
 "chat-assistant-sheet-width",
 "--assistant-sheet-width",
 true
 )Claude Code Docs home pageEnglishSearch...⌘KAsk AIClaude Developer PlatformClaude Code on the WebClaude Code on the WebSearch...NavigationGetting startedClaude Code overviewGetting startedBuild with Claude CodeAdministrationConfigurationReferenceAgent SDKWhat&#x27;s NewResourcesGetting startedOverviewQuickstartChangelogCore conceptsHow Claude Code worksExtend Claude CodeExplore the .claude directoryExplore the context windowUse Claude CodeStore instructions and memoriesPermission modesCommon workflowsBest practicesPlatforms and integrationsOverviewRemote ControlClaude Code on the webClaude Code on desktopChrome extension (beta)Computer use (preview)Visual Studio CodeJetBrains IDEsCode review & CI/CDClaude Code in Slackdocument.documentElement.setAttribute('data-page-mode', "none");(self.__next_s=self.__next_s||[]).push([0,{"suppressHydrationWarning":true,"children":"(function m(a,b,c){if(!document.getElementById(\"footer\")?.classList.contains(\"advanced-footer\")||\"maple\"===b||\"willow\"===b||\"almond\"===b||\"luma\"===b||\"sequoia\"===b)return;let d=document.documentElement.getAttribute(\"data-banner-state\"),e=null!=d?\"visible\"===d:c,f=document.documentElement.getAttribute(\"data-page-mode\"),g=document.getElementById(\"navbar\"),h=document.getElementById(\"navigation-items\"),i=document.getElementById(\"sidebar\"),j=document.getElementById(\"footer\"),k=document.getElementById(\"table-of-contents-content\"),l=document.getElementById(\"banner\"),m=e?l?.offsetHeight??40:0,n=(e?a-2.5:a)*16+m;if(!j||\"center\"===f)return;let o=j.getBoundingClientRect().top,p=window.innerHeight-o,q=(h?.clientHeight??0)+n+32*(\"mint\"===b||\"linden\"===b);if(i\u0026\u0026h)if(p\u003e0){let a=Math.max(0,q-o);i.style.bottom=`${p}px`,i.style.top=`${n-a}px`}else i.style.bottom=\"\",i.style.top=e?`calc(${a-2.5}rem + var(--banner-height, 2.5rem))`:`${a}rem`,i.style.height=\"auto\";k\u0026\u0026g\u0026\u0026(p\u003e0?k.style.top=\"custom\"===f?`${g.clientHeight-p}px`:`${40+g.clientHeight-p}px`:k.style.top=\"\")})(\n (function l(a,b,c){let d=document.documentElement.getAttribute(\"data-banner-state\"),e=2.5*!!(null!=d?\"visible\"===d:b),f=3*!!a,g=4,h=e+g+f;switch(c){case\"mint\":case\"palm\":break;case\"aspen\":f=2.5*!!a,g=3.5,h=e+f+g;break;case\"luma\":g=3,h=e+g;break;case\"linden\":g=4,h=e+g;break;case\"almond\":g=3.5,h=e+g;break;case\"sequoia\":f=3*!!a,g=3,h=e+g+f}return h})(true, false, \"mint\"),\n \"mint\",\n false,\n)","id":"_mintlify-footer-and-sidebar-scroll-script"}])
/* These styles mirror our design system (converted to plain CSS with Claude's help) from https://ui.product.ant.dev/button */
/* Base button styles */
.btn {
 position: relative;
 display: inline-flex;
 gap: 0.5rem;
 align-items: center;
 justify-content: center;
 flex-shrink: 0;
 min-width: 5rem;
 height: 2.25rem;
 padding: 0.5rem 1rem;
 white-space: nowrap;
 font-family: Styrene;
 font-weight: 600;
 border-radius: 0.5rem;
 &:active {
 transform: scale(0.985);
 }
 /* Size variants */
 &.size-xs {
 height: 1.75rem;
 min-width: 3.5rem;
 padding: 0 0.5rem;
 border-radius: 0.25rem;
 font-size: 0.75rem;
 gap: 0.25rem;
 }
 &.size-sm {
 height: 2rem;
 min-width: 4rem;
 padding: 0 0.75rem;
 border-radius: 0.375rem;
 font-size: 0.75rem;
 }
 &.size-lg {
 height: 2.75rem;
 min-width: 6rem;
 padding: 0 1.25rem;
 border-radius: 0.6rem;
 }
 &:disabled {
 pointer-events: none;
 opacity: 0.5;
 box-shadow: none;
 }
 &:focus-visible {
 outline: none;
 --tw-ring-offset-shadow: var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);
 --tw-ring-shadow: var(--tw-ring-inset) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color);
 box-shadow: var(--tw-ring-offset-shadow), var(--tw-ring-shadow);
 }
 /* Primary variant */
 &.primary {
 font-weight: 600;
 color: hsl(var(--oncolor-100));
 background-color: hsl(var(--accent-main-100));
 background-image: linear-gradient(
 to right,
 hsl(var(--accent-main-100)) 0%,
 hsl(var(--accent-main-200) / 0.5) 50%,
 hsl(var(--accent-main-200)) 100%
 );
 background-size: 200% 100%;
 background-position: 0% 0%;
 border: 0.5px solid hsl(var(--border-300) / 0.25);
 box-shadow: 
 inset 0 0.5px 0px rgba(255, 255, 0, 0.15),
 0 1px 1px rgba(0, 0, 0, 0.05);
 text-shadow: 0 1px 2px rgb(0 0 0 / 10%);
 transition: all 150ms cubic-bezier(0.4, 0, 0.2, 1);
 &:hover {
 background-position: 100% 0%;
 background-image: linear-gradient(
 to right,
 hsl(var(--accent-main-200)) 0%,
 hsl(var(--accent-main-200)) 100%
 );
 }
 &:active {
 background-color: hsl(var(--accent-main-000));
 box-shadow: inset 0 1px 6px rgba(0, 0, 0, 0.2);
 transform: scale(0.985);
 }
 }
 /* Flat variant */
 &.flat {
 font-weight: 500;
 color: hsl(var(--oncolor-100));
 background-color: hsl(var(--accent-main-100));
 transition: background-color 150ms;
 &:hover {
 background-color: hsl(var(--accent-main-200));
 }
 }
 /* Secondary variant */
 &.secondary {
 font-weight: 600;
 color: hsl(var(--text-100) / 0.9);
 background-image: radial-gradient(
 ellipse at center,
 hsl(var(--bg-500) / 0.1) 50%,
 hsl(var(--bg-500) / 0.3) 100%
 );
 border: 0.5px solid hsl(var(--border-400));
 transition: color 150ms, background-color 150ms;
 &:hover {
 color: hsl(var(--text-000));
 background-color: hsl(var(--bg-500) / 0.6);
 }
 &:active {
 background-color: hsl(var(--bg-500) / 0.5);
 }
 }
 /* Outline variant */
 &.outline {
 font-weight: 600;
 color: hsl(var(--text-200));
 background-color: transparent;
 border: 1.5px solid currentColor;
 transition: color 150ms, background-color 150ms;
 &:hover {
 color: hsl(var(--text-100));
 background-color: hsl(var(--bg-400));
 border-color: hsl(var(--bg-400));
 }
 }
 /* Ghost variant */
 &.ghost {
 color: hsl(var(--text-200));
 border-color: transparent;
 transition: color 150ms, background-color 150ms;
 &:hover {
 color: hsl(var(--text-100));
 background-color: hsl(var(--bg-500) / 0.4);
 }
 &:active {
 background-color: hsl(var(--bg-400));
 }
 }
 /* Underline variant */
 &.underline {
 opacity: 0.8;
 text-decoration-line: none;
 text-underline-offset: 3px;
 transition: all 150ms;
 &:hover {
 opacity: 1;
 text-decoration-line: underline;
 }
 &:active {
 transform: scale(0.985);
 }
 }
 /* Danger variant */
 &.danger {
 font-weight: 600;
 color: hsl(var(--oncolor-100));
 background-color: hsl(var(--danger-100));
 transition: background-color 150ms;
 &:hover {
 background-color: hsl(var(--danger-200));
 }
 }
}
/* Anthropic Sans - Static fonts from assets.claude.ai */
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-Regular-Static.otf") format("opentype");
 font-weight: 400;
 font-style: normal;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-RegularItalic-Static.otf") format("opentype");
 font-weight: 400;
 font-style: italic;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-Medium-Static.otf") format("opentype");
 font-weight: 500;
 font-style: normal;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-MediumItalic-Static.otf") format("opentype");
 font-weight: 500;
 font-style: italic;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-Semibold-Static.otf") format("opentype");
 font-weight: 600;
 font-style: normal;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-SemiboldItalic-Static.otf") format("opentype");
 font-weight: 600;
 font-style: italic;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-Bold-Static.otf") format("opentype");
 font-weight: 700;
 font-style: normal;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Sans";
 src: url("https://assets.claude.ai/Fonts/AnthropicSans-Text-BoldItalic-Static.otf") format("opentype");
 font-weight: 700;
 font-style: italic;
 font-display: swap;
}
/* Anthropic Serif Display - for headlines */
@font-face {
 font-family: "Anthropic Serif Display";
 src: url("https://assets.claude.ai/Fonts/AnthropicSerif-Display-Regular-Static.otf") format("opentype");
 font-weight: 400;
 font-style: normal;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Serif Display";
 src: url("https://assets.claude.ai/Fonts/AnthropicSerif-Display-RegularItalic-Static.otf") format("opentype");
 font-weight: 400;
 font-style: italic;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Serif Display";
 src: url("https://assets.claude.ai/Fonts/AnthropicSerif-Display-Medium-Static.otf") format("opentype");
 font-weight: 500;
 font-style: normal;
 font-display: swap;
}
@font-face {
 font-family: "Anthropic Serif Display";
 src: url("https://assets.claude.ai/Fonts/AnthropicSerif-Display-Semibold-Static.otf") format("opentype");
 font-weight: 600;
 font-style: normal;
