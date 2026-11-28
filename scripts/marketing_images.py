# PNG-Bilder der App -> WebP für die Webseite (v7/app/img)
import os,sys
from PIL import Image
src='/home/claude/mk'; dst='/home/claude/junels/server/agent-api/v7/app/img'
os.makedirs(dst,exist_ok=True)
for n in ['m_chat','m_news','m_cards','m_results','m_tasks','m_skills','m_flow','m_watch','m_desktop','m_desktop_cards']:
    f=f'{src}/{n}.png'
    if not os.path.exists(f): continue
    im=Image.open(f).convert('RGB')
    if im.width>1800: im=im.resize((im.width*2//3, im.height*2//3), Image.LANCZOS)
    elif im.width<=800: im=im.resize((600, im.height*600//im.width), Image.LANCZOS)
    im.save(f'{dst}/{n}.webp','WEBP',quality=82,method=6)
    print(n, im.size, os.path.getsize(f'{dst}/{n}.webp')//1024,'KB')
