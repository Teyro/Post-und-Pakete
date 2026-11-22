.pragma library
.import "sprache.js" as S

// Gemeinsame Logik der Linux-App und des Plasma-Widgets (wie PaketKern der Apple-Apps).

var t = S.t;

var DIENSTE = {
    dhl: { name: "DHL", farbe: "#FFCC00", schrift: "#D40511" },
    hermes: { name: "Hermes", farbe: "#0091CD", schrift: "#FFFFFF" },
    dpd: { name: "DPD", farbe: "#DC0032", schrift: "#FFFFFF" },
    gls: { name: "GLS", farbe: "#10337A", schrift: "#FFD900" },
    ups: { name: "UPS", farbe: "#40291A", schrift: "#FFB500" },
    amazon: { name: "Amazon", farbe: "#232F3E", schrift: "#FF9900" }
};
var ALLE = ["dhl", "hermes", "dpd", "gls", "ups", "amazon"];

function dienst(d) { return DIENSTE[d] || { name: String(d || "").toUpperCase(), farbe: "#B8854D", schrift: "#FFFFFF" }; }

/** Dienst an der Nummer erkennen ("" = nicht eindeutig, z. B. 14 Ziffern bei Hermes und DPD) */
function dienstVonNummer(nummer) {
    var n = String(nummer || "").replace(/\s+/g, "").toUpperCase();
    if (/^(TBA\d{9,14}|\d{3}-\d{7}-\d{7})$/.test(n)) return "amazon";
    if (/^(JJD\d{12,20}|00\d{18}|\d{20}|\d{12})$/.test(n)) return "dhl";
    if (/^H[0-9A-Z]{19}$/.test(n)) return "hermes";
    if (/^1Z[0-9A-Z]{16}$/.test(n)) return "ups";
    return "";
}

/** Sendungsnummer in einem Text (z. B. aus der Zwischenablage) */
function nummerIn(text) {
    var m = String(text || "").toUpperCase().match(/TBA\d{9,14}|\d{3}-\d{7}-\d{7}|JJD\d{12,20}|1Z[0-9A-Z]{16}|H[0-9A-Z]{19}|\d{11,20}/);
    return m ? m[0] : "";
}

function verfolgenAdresse(s) {
    if (/^https:\/\//.test(s.verfolgen || "")) return s.verfolgen;
    var n = encodeURIComponent(s.nummer || "");
    if (!n) return "";
    switch (s.dienst) {
    case "hermes": return "https://www.myhermes.de/empfangen/sendungsverfolgung/sendungsinformation#" + n;
    case "dpd": return "https://tracking.dpd.de/status/de_DE/parcel/" + n;
    case "gls": return "https://gls-group.com/DE/de/paketverfolgung?match=" + n;
    case "ups": return "https://www.ups.com/track?loc=de_DE&tracknum=" + n;
    case "amazon": return "https://track.amazon.de/tracking/" + n;
    default: return "https://www.dhl.de/de/privatkunden/pakete-empfangen/verfolgen.html?piececode=" + n;
    }
}

/** Antwort von /api/briefankuendigung/briefe → nur die Pakete, mit festen Feldern */
function sendungenAus(antwort) {
    return ((antwort && antwort.briefe) || []).filter(function (b) { return b.art === "paket"; }).map(function (b) {
        return {
            id: b.id, datum: b.datum || 0, absender: b.absender || "", name: b.name || "", nummer: b.sendung || "",
            dienst: b.dienst || "dhl", dienstName: b.dienst_name || dienst(b.dienst || "dhl").name, stand: b.stand || "unterwegs",
            erwartet: b.erwartet || "", zeitfenster: b.zeitfenster || "", kundenkonto: b.kundenkonto || "", verfolgen: b.verfolgen || "",
            manuell: !!b.manuell, statusText: b.status_text || "", problem: !!b.problem, erledigt: !!b.erledigt,
            kontoId: b.konto || "", kontoName: b.konto_name || "", anbieter: b.anbieter || "", quelle: "ha", ruecksendung: !!b.ruecksendung,
            abholcode: b.abholcode || "", abholort: b.abholort || "", abholadresse: b.abholadresse || "", abholfrist: b.abholfrist || "",
            ruecksendefrist: b.ruecksendefrist || "",
            ereignisse: (b.ereignisse || []).filter(function (e) { return e && e.text; })
                .map(function (e) { return { zeit: e.zeit ? Date.parse(e.zeit) || 0 : 0, text: e.text, ort: e.ort || "" }; })
        };
    });
}

/** Pakete aus „Paket Tracker“ (parcel_tracker): GET /api/states → Sendungen (Kennung „pt:<nummer>“) */
function paketTrackerAus(zustaende) {
    var stand = function (z, tage) {
        if (z === "out_for_delivery") return "heute";
        if (z === "awaiting_pickup") return "abholbereit";
        if (z === "delivered") return "zugestellt";
        return tage === 0 ? "heute" : "unterwegs";
    };
    return (zustaende || []).filter(function (z) {
        return z && /^sensor\.paket_/.test(z.entity_id || "") && z.attributes && z.attributes.number && z.attributes.carrier;
    }).map(function (z) {
        var a = z.attributes;
        var von = a.eta_from || "", bis = a.eta_to || "";
        return {
            id: "pt:" + a.number, datum: Date.parse(a.last_update || z.last_changed || "") || Date.now(), absender: a.name || "", name: "",
            nummer: a.tracking_ref || a.number, dienst: a.carrier, dienstName: a.carrier_name || dienst(a.carrier).name, stand: stand(z.state, a.days_until),
            erwartet: a.eta_date || "", zeitfenster: von ? (bis ? von + "–" + bis : von) : "", kundenkonto: "", verfolgen: a.tracking_url || "",
            manuell: true, statusText: a.status_text || "", problem: z.state === "exception", erledigt: false,
            kontoId: "", kontoName: "", anbieter: "Paket Tracker", quelle: "ha", ruecksendung: false,
            abholcode: "", abholort: a.pickup_point || "", abholadresse: "", abholfrist: a.pickup_until || "", ruecksendefrist: "",
            ereignisse: (a.events || []).filter(function (e) { return e && e.text; })
                .map(function (e) { return { zeit: e.timestamp ? Date.parse(e.timestamp) || 0 : 0, text: e.text, ort: e.location || "" }; })
        };
    }).sort(function (x, y) { return y.datum - x.datum; });
}

/** Nummer aus „pt:<nummer>“, sonst "" */
function paketTrackerNummer(id) { return String(id || "").indexOf("pt:") === 0 ? String(id).slice(3) : ""; }

function titel(s) { return s.name || s.absender || s.nummer || t("Paket"); }
function fertig(s) { return s.stand === "zugestellt" || s.erledigt; }

function isoTag(ms) {
    var d = new Date(ms);
    return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2);
}

function kommtHeute(s, jetzt) {
    return !fertig(s) && (s.stand === "heute" || s.stand === "abholbereit" || (!!s.erwartet && s.erwartet === isoTag(jetzt)));
}

/** 1…4: angekündigt · unterwegs · in Zustellung/abholbereit · zugestellt */
function stufe(s) {
    if (s.stand === "zugestellt") return 4;
    if (s.stand === "heute" || s.stand === "abholbereit") return 3;
    return s.ereignisse && s.ereignisse.length ? 2 : 1;
}

/** {heute, unterwegs, zugestellt, aktiv} – zugestellte der letzten `tage` Tage */
function gruppen(liste, jetzt, tage) {
    var g = { heute: [], unterwegs: [], zugestellt: [] };
    var grenze = jetzt - (tage || 14) * 86400000;
    (liste || []).forEach(function (s) {
        if (fertig(s)) { if (s.datum >= grenze) g.zugestellt.push(s); }
        else if (kommtHeute(s, jetzt)) g.heute.push(s);
        else g.unterwegs.push(s);
    });
    function termin(a, b) {
        var x = a.erwartet || "9999", y = b.erwartet || "9999";
        return x !== y ? (x < y ? -1 : 1) : b.datum - a.datum;
    }
    g.heute.sort(function (a, b) {
        var aa = a.stand === "abholbereit", bb = b.stand === "abholbereit";
        return aa !== bb ? (aa ? 1 : -1) : termin(a, b);
    });
    g.unterwegs.sort(termin);
    g.zugestellt.sort(function (a, b) { return b.datum - a.datum; });
    g.aktiv = g.heute.concat(g.unterwegs);
    return g;
}

var TAGE = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];

/** „kommt morgen, 10:00–13:00“, „voraussichtlich Fr 23.10.“, „zur Abholung bereit“ */
function standText(s, jetzt) {
    if (s.stand === "zugestellt") return t("zugestellt");
    if (s.erledigt) return t("angekommen");
    if (s.stand === "abholbereit") return t("zur Abholung bereit");
    var f = s.zeitfenster ? ", " + s.zeitfenster : "";
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s.erwartet || "");
    if (m) {
        var d = new Date(+m[1], +m[2] - 1, +m[3]), h = new Date(jetzt);
        var tage = Math.round((d - new Date(h.getFullYear(), h.getMonth(), h.getDate())) / 86400000);
        var tm = d.getDate() + "." + (d.getMonth() + 1) + ".";
        if (tage === 0) return t("kommt heute") + f;
        if (tage === 1) return t("kommt morgen") + f;
        if (tage < 0) return s.stand === "heute" ? t("kommt heute") + f : t("überfällig seit %1", tm);
        return t("voraussichtlich %1", tage < 7 ? t(TAGE[d.getDay()]) + " " + tm : tm) + f;
    }
    if (s.stand === "heute") return t("kommt heute") + f;
    if (s.problem) return t("Problem bei der Zustellung");
    return s.ereignisse && s.ereignisse.length ? t("unterwegs") : t("angekündigt");
}

/** Paket liegt zum Abholen bereit und wir kennen Code oder Ort */
function zumAbholen(s) {
    return s.stand === "abholbereit" && !s.erledigt && !!(s.abholcode || s.abholort || s.abholadresse);
}

/** Rückgabefristen bekannter Shops in Tagen ab Zustellung */
var RUECKGABE = [["zalando", 100], ["about you", 100], ["aboutyou", 100], ["ikea", 365], ["decathlon", 365], ["tchibo", 30], ["otto", 30],
    ["amazon", 30], ["h&m", 30], ["hm.com", 30], ["mediamarkt", 30], ["media markt", 30], ["saturn", 30], ["thalia", 14], ["lidl", 30],
    ["bonprix", 30], ["baur", 30], ["galeria", 30], ["esprit", 30], ["c&a", 30], ["zara", 30], ["mango", 30], ["asos", 28], ["shein", 45],
    ["temu", 90], ["apple", 14], ["notebooksbilliger", 30], ["alternate", 14], ["cyberport", 14], ["conrad", 30], ["douglas", 30],
    ["flaconi", 30]];

function tagAus(iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || "");
    return m ? new Date(+m[1], +m[2] - 1, +m[3]).getTime() : 0;
}

/** Ms des letzten Rückgabetags oder 0 */
function rueckgabeBis(s) {
    if (!fertig(s) || s.ruecksendung) return 0;
    var d = tagAus(s.ruecksendefrist);
    if (d) return d;
    var shop = String(s.name || s.absender || "").toLowerCase(), n = 0;
    for (var i = 0; i < RUECKGABE.length && !n; i++) if (shop.indexOf(RUECKGABE[i][0]) >= 0) n = RUECKGABE[i][1];
    if (!n && s.dienst === "amazon") n = 30;
    if (!n) return 0;
    var zu = (s.ereignisse || []).reduce(function (m, e) { return Math.max(m, e.zeit || 0); }, 0) || s.datum;
    if (!zu) return 0;
    var z = new Date(zu);
    return new Date(z.getFullYear(), z.getMonth(), z.getDate() + n).getTime();
}

/** „heute“, „morgen“, „Fr 7.11.“, „7.11.“ */
function kurzTag(ms, jetzt) {
    var d = new Date(ms), h = new Date(jetzt);
    var tage = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(h.getFullYear(), h.getMonth(), h.getDate())) / 86400000);
    var tm = d.getDate() + "." + (d.getMonth() + 1) + ".";
    if (tage === 0) return t("heute");
    if (tage === 1) return t("morgen");
    return tage > 1 && tage < 7 ? t(TAGE[d.getDay()]) + " " + tm : tm;
}

/** Rückgabefrist noch offen (heute oder später)? */
function rueckgabeOffen(s, jetzt) {
    var b = rueckgabeBis(s), h = new Date(jetzt);
    return b > 0 && b >= new Date(h.getFullYear(), h.getMonth(), h.getDate()).getTime();
}

/** Wunschnachbar/Ablageort beim Dienst einstellen */
function paketsteuerung(s) {
    var n = encodeURIComponent(s.nummer || "");
    if (s.dienst === "hermes") return "https://www.myhermes.de/empfangen/zustelloptionen/";
    if (s.dienst === "dpd") return "https://my.dpd.de/redirect.aspx?action=1&pno=" + n;
    if (s.dienst === "amazon") return "https://www.amazon.de/gp/css/order-history";
    return verfolgenAdresse(s);
}

/** Route zur Abholstelle (OpenStreetMap, zu Fuß) */
function routeAdresse(s) {
    var ziel = [s.abholort, s.abholadresse].filter(function (x) { return x; }).join(", ");
    return "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&to=" + encodeURIComponent(ziel);
}

/** Stand · Kundenkonto (bzw. Postfach) */
function zeile(s, jetzt, mitKonto) {
    var teile = [zumAbholen(s) && s.abholcode ? t("Abholcode %1", s.abholcode) + (s.abholort ? " · " + s.abholort : "") : standText(s, jetzt)];
    if (fertig(s) && rueckgabeOffen(s, jetzt)) teile.push(t("Rückgabe bis %1", kurzTag(rueckgabeBis(s), jetzt)));
    if (s.kundenkonto) teile.push(s.kundenkonto); else if (mitKonto && s.kontoName) teile.push(s.kontoName);
    return teile.join(" · ");
}

function anzahl(n) { return n === 1 ? t("1 Paket") : t("%1 Pakete", n); }
function kopfTitel(aktiv) { return aktiv.length ? t("%1 unterwegs", anzahl(aktiv.length)) : t("Keine Pakete unterwegs"); }

/** „heute 07:12“, „gestern 18:00“, „Di 20.10. 18:00“ */
function ereigniszeit(ms, jetzt) {
    if (!ms) return "";
    var d = new Date(ms), h = new Date(jetzt);
    var uhr = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
    if (d.toDateString() === h.toDateString()) return t("heute %1", uhr);
    var g = new Date(jetzt - 86400000);
    if (d.toDateString() === g.toDateString()) return t("gestern %1", uhr);
    return t(TAGE[d.getDay()]) + " " + d.getDate() + "." + (d.getMonth() + 1) + ". " + uhr;
}

/** Mitteilung bei neuem Stand: {titel, text} oder null */
function mitteilung(alt, neu) {
    var text = titel(neu) + " (" + neu.dienstName + ")";
    if (neu.problem && !(alt && alt.problem)) return { titel: t("⚠️ Problem mit der Sendung"), text: text + (neu.statusText ? " – " + neu.statusText : "") };
    if (!alt || alt.stand === neu.stand || neu.erledigt) return null;
    var titelText = { heute: t("📦 Kommt heute"), abholbereit: t("📦 Zur Abholung bereit"), zugestellt: t("📦 Zugestellt") }[neu.stand];
    if (neu.stand === "abholbereit" && zumAbholen(neu))
        text += " – " + [neu.abholcode ? t("Abholcode %1", neu.abholcode) : "", neu.abholort].filter(function (x) { return x; }).join(" · ");
    if (neu.stand === "zugestellt" && rueckgabeOffen(neu, Date.now())) text += " – " + t("Rückgabe bis %1", kurzTag(rueckgabeBis(neu), Date.now()));
    return titelText ? { titel: titelText, text: text } : null;
}

/** "homeassistant.local:8123/" → "http://homeassistant.local:8123" */
function adresse(a) {
    var s = String(a || "").trim().replace(/\/+$/, "");
    if (s && s.indexOf("://") < 0) s = "http://" + s;
    return s;
}

/** Farbe der Standzeile (Kirigami-Farben werden im QML eingesetzt): "heute" | "abholbereit" | "problem" | "" */
function standArt(s, jetzt) {
    if (s.problem) return "problem";
    if (s.stand === "abholbereit") return "abholbereit";
    return kommtHeute(s, jetzt) ? "heute" : "";
}

/** Sendungen aus Home Assistant und direkt verfolgte zusammenführen (gleiche Nummer: Home Assistant gewinnt, Verlauf ergänzt) */
function zusammenfuehren(ha, direkt) {
    var erg = (ha || []).map(function (s) { return Object.assign({ quelle: "ha" }, s); });
    (direkt || []).forEach(function (d) {
        var i = -1;
        for (var k = 0; k < erg.length; k++) if (d.nummer && String(erg[k].nummer).toUpperCase() === d.nummer) { i = k; break; }
        if (i < 0) { erg.push(d); return; }
        var h = Object.assign({}, erg[i]);
        // Die eigene Abfrage weiß mehr (Verlauf, weiterer Stand): deren Stand übernehmen
        if (d.ereignisse.length && (!h.ereignisse.length || stufe(d) > stufe(h))) {
            h.stand = d.stand; h.problem = d.problem; h.ereignisse = d.ereignisse; h.anbieter = d.anbieter;
            if (d.statusText) h.statusText = d.statusText;
            if (d.zeitfenster) h.zeitfenster = d.zeitfenster;
            h.datum = Math.max(h.datum, d.datum);
        }
        if (!h.ereignisse.length) h.ereignisse = d.ereignisse;
        if (!h.erwartet) h.erwartet = d.erwartet;
        if (!h.name) h.name = d.name;
        h.ruecksendung = h.ruecksendung || d.ruecksendung;
        if (!h.anbieter) h.anbieter = d.anbieter;
        erg[i] = h;
    });
    return erg;
}

/** Was dieses Gerät über eine Sendung weiß – für Home Assistant (ab Integration 1.8), damit alle Geräte denselben Stand sehen */
function standInfo(s) {
    return { stand: s.stand, text: s.statusText || "", erwartet: s.erwartet || "", zeitfenster: s.zeitfenster || "", problem: !!s.problem,
             ruecksendung: !!s.ruecksendung, erledigt: !!s.erledigt,
             ereignisse: (s.ereignisse || []).slice(0, 40).map(function (e) {
                 return { zeit: e.zeit ? new Date(e.zeit).toISOString() : "", text: e.text, ort: e.ort || "" };
             }) };
}

/** Direkt verfolgte Sendungen, die Home Assistant noch nicht (oder mit älterem Stand) kennt.
 *  gesendet: Nummer → zuletzt geschickter Stand (nicht zweimal dasselbe schicken) */
function abgleich(ha, direkt, gesendet) {
    return (direkt || []).filter(function (d) {
        if (!d.nummer) return false;
        var sig = d.stand + "|" + (d.ereignisse || []).length + "|" + !!d.erledigt + "|" + !!d.ruecksendung;
        if (gesendet[d.nummer] === sig) return false;
        var h = null;
        for (var i = 0; i < (ha || []).length && !h; i++) if (String(ha[i].nummer).toUpperCase() === d.nummer) h = ha[i];
        if (h && stufe(h) >= stufe(d) && h.ereignisse.length >= (d.ereignisse || []).length
            && (h.erledigt || !d.erledigt) && (h.ruecksendung || !d.ruecksendung)) return false;
        d.signatur = sig;
        return true;
    });
}

// --- Briefe (Deutsche Post Briefankündigung, nur mit Home Assistant) ---

/** Antwort von /api/briefankuendigung/briefe → nur die Briefe */
function briefeAus(antwort) {
    return ((antwort && antwort.briefe) || []).filter(function (b) { return (b.art || "brief") === "brief"; }).map(function (b) {
        return { id: b.id, datum: b.datum || 0, absender: b.absender || "", bild: !!b.bild, wichtig: !!b.wichtig, erledigt: !!b.erledigt,
                 kontoId: b.konto || "", kontoName: b.konto_name || "", brief: true };
    }).sort(function (a, b) { return b.datum - a.datum; });
}

function briefTitel(b) { return b.absender || t("Absender unbekannt"); }

/** {heute, unterwegs, angekommen, offen}: älter als `tage` Tage zählt als angekommen */
function briefGruppen(liste, jetzt, tage) {
    var g = { heute: [], unterwegs: [], angekommen: [] };
    var grenze = jetzt - (tage || 5) * 86400000, heute = new Date(jetzt).toDateString();
    (liste || []).forEach(function (b) {
        if (b.erledigt || b.datum < grenze) { if (b.datum >= jetzt - 14 * 86400000) g.angekommen.push(b); }
        else if (new Date(b.datum).toDateString() === heute) g.heute.push(b);
        else g.unterwegs.push(b);
    });
    var w = function (a, b) { return a.wichtig !== b.wichtig ? (a.wichtig ? -1 : 1) : b.datum - a.datum; };
    g.heute.sort(w); g.unterwegs.sort(w);
    g.offen = g.heute.concat(g.unterwegs);
    return g;
}

/** „heute“, „gestern“, „Mo 26.10.“ */
function tagText(ms, jetzt) {
    var d = new Date(ms), h = new Date(jetzt);
    if (d.toDateString() === h.toDateString()) return t("heute");
    if (d.toDateString() === new Date(jetzt - 86400000).toDateString()) return t("gestern");
    return t(TAGE[d.getDay()]) + " " + d.getDate() + "." + (d.getMonth() + 1) + ".";
}

/** „angekündigt heute · Johanna“ bzw. „angekommen“ */
function briefZeile(b, jetzt, mitKonto) {
    var teile = [b.erledigt ? t("angekommen") : t("angekündigt %1", tagText(b.datum, jetzt))];
    if (mitKonto && b.kontoName) teile.push(b.kontoName);
    return teile.join(" · ");
}

function briefeAnzahl(n) { return n === 1 ? t("1 Brief") : t("%1 Briefe", n); }

/** Kopf: „2 Briefe, 3 Pakete unterwegs“ */
function postTitel(briefe, pakete) {
    var teile = [];
    if (briefe.length) teile.push(briefeAnzahl(briefe.length));
    if (pakete.length) teile.push(anzahl(pakete.length));
    return teile.length ? t("%1 unterwegs", teile.join(", ")) : t("Keine Post unterwegs");
}

/** Bytes eines Umschlagbilds → data:-Adresse (QML-Bilder können keinen Token mitschicken) */
var _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function bildAdresse(bytes) {
    var typ = bytes[0] === 0x89 && bytes[1] === 0x50 ? "image/png" : bytes[0] === 0x47 && bytes[1] === 0x49 ? "image/gif"
            : bytes[0] === 0x52 && bytes[1] === 0x49 ? "image/webp" : "image/jpeg";
    var teile = [], n = bytes.length;
    for (var i = 0; i < n; i += 3) {
        var a = bytes[i], b = i + 1 < n ? bytes[i + 1] : 0, c = i + 2 < n ? bytes[i + 2] : 0;
        var x = (a << 16) | (b << 8) | c;
        teile.push(_B64.charAt((x >> 18) & 63) + _B64.charAt((x >> 12) & 63) + (i + 1 < n ? _B64.charAt((x >> 6) & 63) : "=") + (i + 2 < n ? _B64.charAt(x & 63) : "="));
    }
    return "data:" + typ + ";base64," + teile.join("");
}
