# AI Prime Cursor Manager (Windows) — eksperimentaalne

Copyright © 2026 secocyber. All rights reserved.

[English](README.md) | Eesti | [Français](README.fr.md) | [Deutsch](README.de.md) | [فارسی](README.fa.md)

**Olek: eksperimentaalne / alpha.** See on Windowsi tööriist, millega saab katsetada Cursorist AI Prime Techi suunduvat autentimisega kohalikku OpenAI-ühilduvat silda. Sild ja tunneli staatilised lepingutestid läbivad praeguses arenduskeskkonnas kontrollid, kuid WPF-i graafilist kasutajaliidest tervikuna ega töötavat Cloudflare Quick Tunnelit pole puhtas Windowsi keskkonnas algusest lõpuni valideeritud. Ära käsitle praegust lähtekoodi tootmisvalmis väljalaskena.

## Funktsioonid

- Windows PowerShelli/WPF-i juhtpaneel AI Prime Techi API-võtme testimiseks ja sellele võtmele saadaolevate mudeli-ID-de laadimiseks.
- Kohalik Node.js-i sild, mis kuulab aadressil `127.0.0.1`, pakub Cursorile üht seadistatavat mudelialiast ning edastab päringud AI Prime Techile.
- Bearer-võtmega autentimine Cursori ja kohaliku silla vahel. Cursorile tuleb anda silla võti, mitte AI Prime Techi API-võti.
- Silla juhtimine, logid, Cursori seadistusväärtused, mudeli valik ja eksperimentaalne Cloudflare Quick Tunneli haldus.
- Võrguühenduseta suitsutestid, mis kasutavad kohalikku näidisserverit ega vaja päris API mandaate.

## Liidese keeled

WPF-i liidese paremas ülanurgas on keelevalik. Toetatud keeled on **inglise keel (vaikimisi), eesti keel, prantsuse keel ja saksa keel**. Keele vahetamine uuendab tõlgitud silte, vahekaarte, nuppe, vihjeid, turvateadet ja olekuteateid. Valitud keel salvestatakse kasutajapõhistesse seadistustesse ja taastatakse rakenduse järgmisel käivitamisel.

Tehnilised identifikaatorid, mudeli-ID-d, URL-id ja teenusepakkuja vastused jäävad algkujule, et neid saaks täpselt kopeerida.

## Olulised piirangud

- **Cursori sisseehitatud Explore'i piirang:** see projekt ei saa muuta Cursori enda tootepiiranguid. Olenevalt Cursori versioonist ja seadistusest ei pruugi BYOK-i kohandatud mudelit saada sisseehitatud Explore Subagentile eraldi määrata.
- **Remote Cursor ja localhost:** kaug- või pilvepäring ei pääse otse sinu arvuti aadressile `127.0.0.1`. Eksperimentaalne Quick Tunneli vahekaart pakub testimiseks ajutist avalikku HTTPS-aadressi. Hoia autentimine lubatuna ja peata tunnel pärast kasutamist. Ära kasuta autentimata avalikku silda.
- **Windowsi valideerimine:** selles arenduskeskkonnas ei saa WPF-i käivitada. Enne stabiilset väljalaset peab Windowsi testija kontrollima rakenduse käivitumist, silla käivitamist/peatamist, allalaadimise edenemist ja Quick Tunnelit päris Windowsis.
- Eelkompileeritud EXE-faili ei hoita lähtekoodirepositooriumis enne, kui selle vastavus praegusele lähtekoodile on kontrollitud. Käivita selle asemel PowerShelli käivitaja täielikult lahti pakitud kaustast.
- Silla kaudu saadetud promptid ja kood töödeldakse AI Prime Techis. Ära saada konfidentsiaalset koodi, kui sinu eeskirjad seda ei luba.

## Nõuded

- Windows 10/11
- Windows PowerShell 5.1 või uuem koos WPF-iga
- Node.js 20 või uuem, kättesaadav `PATH`-i kaudu
- Aktiivne AI Prime Techi API-võti, millel on valitud mudeli kasutusõigus

## Käivitamine lähtekoodist

1. Laadi see repositoorium alla või klooni see ja paki see tavalisse kausta (mitte otse ZIP-faili sisse).
2. Käivita `Start-AI-Prime-Cursor-Manager.bat`.
3. Kui käivitamine ebaõnnestub, käivita `Start-AI-Prime-Cursor-Manager-Diagnostics.bat` ja jaga ainult veateksti, mitte võtmeid ega tunneli URL-e.
4. Sisesta Dashboardis AI Prime Techi API-võti ja vali **Refresh model catalog**.
5. Vali mudel ja käivita enne pikemat kasutussessiooni **Test selected model**.
6. Käivita kohalik Bridge. Eraldi Cursori profiilis seadista **Use OpenAI API Key** ja **Override OpenAI Base URL**, kasutades Cursor Setupi kuvatud väärtusi. Kasuta *kohaliku silla võtit*, mitte AI Prime Techi võtit.

### Võrguühenduseta testide käivitamine

Node.js 20 või uuema versiooniga:

```powershell
npm test
npm run check
```

Või tee Windowsis topeltklõps failil `Run-Bridge-Smoke-Tests.bat`. Testid kasutavad näidisserverit ega saada päringuid AI Prime Techi.

## Turvalisus

- Ära lisa GitHubi API-võtmeid, silla võtmeid, juurdepääsutokeneid, logisid, seadefaile ega Cloudflare'i tunneli URL-e.
- Sild peab kuulama aadressil `127.0.0.1` ja API lõpp-punktid peavad nõudma juhuslikku kohalikku Beareri võtit.
- Ära avalda silda otse LAN-is ega internetis. Ajutine avalik tunnel on ainult kontrollitud testimiseks; võti on endiselt nõutav.
- Vaheta iga võti, mis on kunagi kleebitud vestlusesse, ekraanipilti, issue'sse või logisse.

## Valideeritud lähtekoodipaketi allalaadimine (alpha)

Käsitsi käivitatav GitHub Actionsi töövoog loob ainult lähtekoodi sisaldava ZIP-faili ja kontrollib arhiivi pärast lahtipakkimist enne selle üleslaadimist:

1. Ava [Actions](https://github.com/omid-cyber/ai-prime-cursor-manager/actions/workflows/package-alpha-source.yml).
2. Vali **Package Alpha Source Bundle**, vali harus `main` **Run workflow** ja oota töövoo lõppemist.
3. Laadi edukalt käivitunud töövoo artefakt `ai-prime-cursor-manager-source-<commit>` alla. Artefakt aegub 14 päeva pärast.
4. Paki ZIP täielikult tavalisse kausta ja käivita `Start-AI-Prime-Cursor-Manager.bat`.

Töövoog kontrollib Node'i süntaksit, Bridge'i/Tunneli võrguühenduseta suitsuteste ning PowerShelli/XAML-i eelkontrolli. Seejärel pakib töövoog ZIP-faili uude kausta lahti ja kordab kontrolle selle koopia peal.

**See on valideeritud lähtekoodipakett, mitte kompileeritud EXE ega stabiilne väljalase.** WPF-i tegelik liides ja töötav Cloudflare Quick Tunnel vajavad endiselt käsitsi testimist Windows 10/11 peal. Edasilevitamise litsentsi pole valitud; vaata faili `LICENSE-DECISION.md`.

## Projekti hetkeseis

Kood sisaldab varasemate Windowsi käitusvigade parandusi, seega ei asenda lähtekoodi testid WPF-i täielikku suitsutesti päris Windowsis. Vaata [TEST-REPORT.md](TEST-REPORT.md) ja [docs/RELEASING.md](docs/RELEASING.md). Vigadest teatamisel eemalda saladused ja lisa täpne veatekst.

## Litsents

Projekti omanik pole litsentsi veel valinud. Kuni litsentsi lisamiseni eelda, et kõik õigused on kaitstud; ära levita tarkvara edasi ega loo tuletatud teoseid. Enne avatud lähtekoodiga projektina väljakuulutamist vali litsents.
