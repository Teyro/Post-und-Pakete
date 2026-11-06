.pragma library
.import "logik.js" as Logik

// Direkt verfolgen (ohne Home Assistant): Anbieter der Reihe nach fragen, der erste mit brauchbarer Antwort gewinnt.
// DHL (Schlüssel) → UPS (Zugang) → 17TRACK (Schlüssel) → Ship24 (Schlüssel) → öffentliche Seiten von GLS und DPD.
// Gleiche Auswertung wie PaketKern (Swift) und die Home-Assistant-Integration (Python).

var AGENT = "Mozilla/5.0 (X11; Linux x86_64) PostUndPakete/2.0";

function anfrage(methode, url, kopf, koerper) {
    return new Promise(function (ok, fehler) {
        var x = new XMLHttpRequest();
        x.open(methode, url);
        x.timeout = 20000;
        for (var k in (kopf || {})) x.setRequestHeader(k, kopf[k]);
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            if (x.status === 401 || x.status === 403) return fehler("abgelehnt");
            if (x.status === 404) return fehler("unbekannt");
            if (x.status === 429) return fehler("kontingent");
            if (x.status < 200 || x.status >= 300) return fehler(x.status === 0 ? "netz" : "HTTP " + x.status);
            try { ok(JSON.parse(x.responseText)); } catch (e) { fehler("antwort"); }
        };
        x.send(koerper === undefined || koerper === null ? null : typeof koerper === "string" ? koerper : JSON.stringify(koerper));
    });
}

function ereignis(zeit, text, ort) {
    if (!text) return null;
    var ms = zeit ? Date.parse(zeit) : 0;
    return { zeit: isNaN(ms) ? 0 : ms, text: String(text).trim(), ort: ort ? String(ort).trim() : "" };
}

function sortiert(liste) {
    var gesehen = {}, erg = [];
    liste.filter(function (e) { return e; }).forEach(function (e) {
        var k = e.zeit + "|" + e.text;
        if (!gesehen[k]) { gesehen[k] = true; erg.push(e); }
    });
    return erg.sort(function (a, b) { return b.zeit - a.zeit; });
}

function tag(s) {
    s = String(s || "");
    if (/^\d{8}$/.test(s)) return s.slice(0, 4) + "-" + s.slice(4, 6) + "-" + s.slice(6);
    var m = /^\d{4}-\d{2}-\d{2}/.exec(s);
    return m ? m[0] : "";
}

function standAusText(t) {
    var s = String(t || "").toLowerCase();
    var nicht = /nicht zugestellt|konnte nicht|not delivered/.test(s);
    if (!nicht && /zugestellt|delivered|ausgeliefert|abgeholt|abholung aus/.test(s)) return "zugestellt";
    if (/zur abholung|abholbereit|liegt in der packstation|liegt in der filiale|pickup|paketshop/.test(s)) return "abholbereit";
    if (nicht) return "unterwegs";
    if (/in zustellung|zustellfahrzeug|out for delivery|wird heute/.test(s)) return "heute";
    return "unterwegs";
}

function spur(o) { return Object.assign({ stand: "unterwegs", erwartet: "", zeitfenster: "", text: "", ereignisse: [], problem: false, ende: false }, o); }

// --- Auswertung je Anbieter ---

function dhl(s) {
    var st = s.status || {}, code = String(st.statusCode || "").toLowerCase(), text = st.description || st.status || "";
    return spur({
        stand: code === "delivered" ? "zugestellt" : standAusText(text), text: text, erwartet: tag(s.estimatedTimeOfDelivery),
        ende: code === "delivered", problem: code === "failure",
        ereignisse: sortiert((s.events || []).map(function (e) {
            return ereignis(e.timestamp, e.description || e.status, ((e.location || {}).address || {}).addressLocality);
        }))
    });
}

function ups(p) {
    var akt = p.activity || [], aktuell = p.currentStatus || ((akt[0] || {}).status) || {};
    var typ = aktuell.type || "", text = aktuell.description || "";
    var termine = p.deliveryDate || [], termin = termine.filter(function (d) { return ["SDD", "RDD", "DEL"].indexOf(d.type) >= 0; })[0] || termine[0] || {};
    var z = p.deliveryTime || {}, von = z.startTime || "", bis = z.endTime || "";
    return spur({
        stand: typ === "D" ? "zugestellt" : standAusText(text), text: text, erwartet: tag(termin.date),
        zeitfenster: von.length >= 4 && bis.length >= 4 ? von.slice(0, 2) + ":" + von.slice(2, 4) + "–" + bis.slice(0, 2) + ":" + bis.slice(2, 4) : "",
        ende: typ === "D", problem: typ === "X",
        ereignisse: sortiert(akt.map(function (a) {
            var t = String(a.date || ""), u = String(a.time || "000000");
            var zeit = t.length === 8 ? t.slice(0, 4) + "-" + t.slice(4, 6) + "-" + t.slice(6) + "T" + u.slice(0, 2) + ":" + u.slice(2, 4) + ":" + u.slice(4, 6) : "";
            var adr = ((a.location || {}).address) || {}, b = (a.status || {}).description || "";
            if (b === b.toUpperCase() && b.length > 3) b = b[0] + b.slice(1).toLowerCase();
            var stadt = adr.city ? adr.city[0] + adr.city.slice(1).toLowerCase() : "";
            return ereignis(zeit, b, [stadt, adr.countryCode].filter(function (x) { return x; }).join(", "));
        }))
    });
}

function siebzehn(info) {
    var status = (info.latest_status || {}).status || "", le = info.latest_event || {};
    var e = (info.time_metrics || {}).estimated_delivery_date || {}, alle = [];
    ((info.tracking || {}).providers || []).forEach(function (p) {
        (p.events || []).forEach(function (x) { alle.push(ereignis(x.time_iso || x.time_utc, (x.description_translation || {}).description || x.description, x.location)); });
    });
    return spur({
        stand: { Delivered: "zugestellt", AvailableForPickup: "abholbereit", OutForDelivery: "heute" }[status] || "unterwegs",
        text: (le.description_translation || {}).description || le.description || "", erwartet: tag(e.from || e.to),
        ende: status === "Delivered" || status === "Expired", problem: status === "DeliveryFailure" || status === "Exception",
        ereignisse: sortiert(alle)
    });
}

function ship24(t) {
    var sh = t.shipment || {}, m = sh.statusMilestone || "";
    var ev = sortiert((t.events || []).map(function (e) { return ereignis(e.occurrenceDatetime, e.status, e.location); }));
    return spur({
        stand: { delivered: "zugestellt", available_for_pickup: "abholbereit", out_for_delivery: "heute" }[m] || "unterwegs",
        erwartet: tag((sh.delivery || {}).estimatedDeliveryDate), text: ev.length ? ev[0].text : "", ereignisse: ev,
        ende: m === "delivered", problem: m === "exception" || m === "failed_attempt"
    });
}

function gls(tu) {
    var info = String(((tu.progressBar || {}).statusInfo) || "").toUpperCase();
    var ev = sortiert((tu.history || []).map(function (h) {
        var adr = h.address || {};
        return ereignis(h.date ? h.date + "T" + (h.time || "00:00:00") : "", h.evtDscr, [adr.city, adr.countryName].filter(function (x) { return x; }).join(", "));
    }));
    var text = ev.length ? ev[0].text : "";
    return spur({ stand: info === "DELIVERED" ? "zugestellt" : info === "INDELIVERY" ? "heute" : standAusText(text), text: text, ereignisse: ev, ende: info === "DELIVERED" });
}

function dpd(d) {
    var infos = d.statusInfo || [], aktuell = null;
    for (var i = infos.length - 1; i >= 0 && !aktuell; i--) if (infos[i].isCurrentStatus) aktuell = infos[i];
    for (var j = infos.length - 1; j >= 0 && !aktuell; j--) if (infos[j].statusHasBeenReached) aktuell = infos[j];
    aktuell = aktuell || {};
    var status = aktuell.status || "", text = aktuell.label || "";
    var ev = sortiert(((d.scanInfo || {}).scan || []).map(function (s) {
        return ereignis(s.date, ((s.scanDescription || {}).content || []).filter(function (c) { return typeof c === "string"; }).join(" "), (s.scanData || {}).location);
    }));
    return spur({
        stand: status === "DELIVERED" ? "zugestellt" : status === "COURIER" || status === "OUT_FOR_DELIVERY" ? "heute" : status === "PICKUP" ? "abholbereit" : standAusText(text),
        text: text, ereignisse: ev, ende: status === "DELIVERED"
    });
}

function dhlOeffentlich(s) {
    var d = s.sendungsdetails || {}, v = d.sendungsverlauf || {};
    var ev = sortiert((v.events || []).map(function (e) { return ereignis(e.datum, String(e.status || "").replace(/  +/g, " "), e.ort); }));
    var text = v.status || (ev.length ? ev[0].text : "");
    var zu = !!d.istZugestellt;
    var stand = zu ? "zugestellt" : standAusText(ev.length ? ev[0].text : text);
    if (!zu && stand === "zugestellt") stand = standAusText(text);
    // Voraussichtliche Zustellung: zustellung.zustellzeitfensterVon/Bis ("2026-11-07" oder mit Uhrzeit)
    var z = d.zustellung || {}, von = String(z.zustellzeitfensterVon || ""), bis = String(z.zustellzeitfensterBis || "");
    var erwartet = "", fenster = "";
    if (!zu && /^\d{4}-\d{2}-\d{2}/.test(von)) {
        erwartet = von.slice(0, 10);
        if (von.indexOf("T") > 0 && bis.indexOf("T") > 0 && von.slice(0, 10) === bis.slice(0, 10)) fenster = von.slice(11, 16) + "–" + bis.slice(11, 16);
    }
    return spur({ stand: stand, text: text, ereignisse: ev, ende: zu, erwartet: erwartet, zeitfenster: fenster });
}

// --- Anbieter ---

/** Alle Anbieter mit Beschreibung (für die Auswahl in den Einstellungen) */
var BESCHREIBUNG = [
    ["DHL", Logik.t("Offizielle DHL-Schnittstelle – eigener kostenloser Schlüssel")],
    ["DHL (ohne Schlüssel)", Logik.t("DHL und Deutsche Post über die öffentliche Sendungsverfolgung – zwei Adressen als Ersatz")],
    ["UPS", Logik.t("Offizielle UPS-Schnittstelle – eigener kostenloser Zugang")],
    ["17TRACK", Logik.t("Fast alle Dienste – Schlüssel, 200 Sendungen frei")],
    ["Ship24", Logik.t("Fast alle Dienste – Schlüssel")],
    ["GLS (öffentlich)", Logik.t("Öffentliche GLS-Seite – inoffiziell")],
    ["DPD (öffentlich)", Logik.t("Öffentliche DPD-Seite – inoffiziell")]
];

function an(s, name) { return (s.aus || []).indexOf(name) < 0; }

var SIEBZEHN = { dhl: 7041, hermes: 100031, dpd: 100007, gls: 101070, ups: 100002 };

function kette(s, dienst) {
    var liste = [];
    if (s.dhl && (dienst === "dhl" || !dienst)) liste.push({ name: "DHL", frage: function (n) {
        return anfrage("GET", "https://api-eu.dhl.com/track/shipments?language=de&trackingNumber=" + encodeURIComponent(n), { "DHL-API-Key": s.dhl })
            .then(function (j) { if (!(j.shipments || [])[0]) throw "unbekannt"; return dhl(j.shipments[0]); });
    } });
    if (s.oeffentlich !== false && (dienst === "dhl" || !dienst)) liste.push({ name: "DHL (ohne Schlüssel)", frage: function (n) {
        function host(h) {
            return anfrage("GET", "https://" + h + "/int-verfolgen/data/search?language=de&piececode=" + encodeURIComponent(n), { "Accept": "application/json" })
                .then(function (j) { var x = (j.sendungen || [])[0]; if (!x || !x.sendungsdetails) throw "unbekannt"; return dhlOeffentlich(x); });
        }
        return host("www.dhl.de").then(null, function () { return host("www.deutschepost.de"); });
    } });
    if (s.upsId && s.upsGeheim && dienst === "ups") liste.push({ name: "UPS", frage: function (n) {
        return anfrage("POST", "https://onlinetools.ups.com/security/v1/oauth/token",
                       { "Authorization": "Basic " + Qt.btoa(s.upsId + ":" + s.upsGeheim), "Content-Type": "application/x-www-form-urlencoded" }, "grant_type=client_credentials")
            .then(function (t) {
                return anfrage("GET", "https://onlinetools.ups.com/api/track/v1/details/" + encodeURIComponent(n) + "?locale=de_DE",
                               { "Authorization": "Bearer " + t.access_token, "transId": String(Date.now()), "transactionSrc": "PostUndPakete" });
            })
            .then(function (j) { var p = (((((j.trackResponse || {}).shipment || [])[0] || {}).package) || [])[0]; if (!p) throw "unbekannt"; return ups(p); });
    } });
    if (s.siebzehn && dienst !== "amazon") liste.push({ name: "17TRACK", frage: function (n) {
        var kopf = { "17token": s.siebzehn, "Content-Type": "application/json" }, e = { number: n };
        if (SIEBZEHN[dienst]) e.carrier = SIEBZEHN[dienst];
        return anfrage("POST", "https://api.17track.net/track/v2.2/register", kopf, [e])
            .then(function () { return anfrage("POST", "https://api.17track.net/track/v2.2/gettrackinfo", kopf, [e]); })
            .then(function (j) { var a = (((j.data || {}).accepted) || [])[0]; if (!a || !a.track_info) throw "unbekannt"; return siebzehn(a.track_info); });
    } });
    if (s.ship24) liste.push({ name: "Ship24", frage: function (n) {
        return anfrage("POST", "https://api.ship24.com/public/v1/trackers/track", { "Authorization": "Bearer " + s.ship24, "Content-Type": "application/json" }, { trackingNumber: n })
            .then(function (j) { var t = (((j.data || {}).trackings) || [])[0]; if (!t) throw "unbekannt"; return ship24(t); });
    } });
    if (s.oeffentlich !== false && dienst === "gls") liste.push({ name: "GLS (öffentlich)", frage: function (n) {
        function host(h) {
            return anfrage("GET", "https://" + h + "/app/service/open/rest/DE/de/rstt001?match=" + encodeURIComponent(n), { "User-Agent": AGENT })
                .then(function (j) { var tu = (j.tuStatus || [])[0]; if (!tu) throw "unbekannt"; return gls(tu); });
        }
        return host("gls-group.com").then(null, function () { return host("gls-group.eu"); });
    } });
    if (s.oeffentlich !== false && dienst === "dpd") liste.push({ name: "DPD (öffentlich)", frage: function (n) {
        return anfrage("GET", "https://tracking.dpd.de/rest/plc/de_DE/" + encodeURIComponent(n), { "User-Agent": AGENT })
            .then(function (j) { var d = (j.parcellifecycleResponse || {}).parcelLifeCycleData; if (!d) throw "unbekannt"; return dpd(d); });
    } });
    return liste.filter(function (a) { return an(s, a.name); });
}

function namen(s, dienst) { return kette(s, dienst).map(function (a) { return a.name; }); }

/** Der Reihe nach fragen → Promise({spur, quelle, fehler: {Anbieter: Grund}}) */
function abfragen(s, nummer, dienst) {
    var liste = kette(s, dienst), fehler = {};
    function naechster(i) {
        if (i >= liste.length) return Promise.resolve({ spur: null, quelle: "", fehler: fehler });
        return liste[i].frage(nummer).then(function (sp) {
            if (!sp.ereignisse.length && !sp.text && !sp.erwartet) { fehler[liste[i].name] = "unbekannt"; return naechster(i + 1); }
            return { spur: sp, quelle: liste[i].name, fehler: fehler };
        }, function (grund) { fehler[liste[i].name] = String(grund); return naechster(i + 1); });
    }
    return naechster(0);
}

/** Stand übernehmen (wie Sendung.uebernehmen in Swift) → neue Sendung */
function uebernehmen(s, sp, quelle) {
    var n = Object.assign({}, s);
    if (sp.stand !== n.stand || sp.ereignisse.length) n.stand = sp.stand;
    if (sp.erwartet) n.erwartet = sp.erwartet;
    if (sp.zeitfenster) n.zeitfenster = sp.zeitfenster;
    if (sp.text) n.statusText = sp.text;
    n.problem = !!sp.problem;
    n.ereignisse = sortiert(sp.ereignisse.concat(s.ereignisse || []));
    n.anbieter = quelle;
    if (JSON.stringify(n) !== JSON.stringify(s)) n.datum = Date.now();
    return n;
}

/** Neue direkt verfolgte Sendung */
function neu(nummer, dienst, name, ruecksendung) {
    var n = String(nummer).replace(/\s+/g, "").toUpperCase();
    var id = "d" + Qt.md5(dienst + ":" + n).slice(0, 19);
    return { id: id, datum: Date.now(), absender: "", name: name || "", nummer: n, dienst: dienst, dienstName: Logik.dienst(dienst).name,
             stand: "unterwegs", erwartet: "", zeitfenster: "", kundenkonto: "", verfolgen: "", manuell: true, statusText: "", problem: false,
             erledigt: false, kontoId: "", kontoName: "", ereignisse: [], quelle: "direkt", anbieter: "", ruecksendung: !!ruecksendung };
}
