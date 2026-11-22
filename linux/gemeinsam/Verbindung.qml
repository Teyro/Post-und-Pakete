/*
 * Verbindung zu Home Assistant (Integration „Briefankündigung“): Sendungen laden, hinzufügen, umbenennen,
 * als angekommen markieren, entfernen. Meldet neue Stände (Signal neuerStand).
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import "logik.js" as Logik
import "anbieter.js" as Anbieter
import "sprache.js" as S

QtObject {
    id: ha

    property string adresse: ""
    property string token: ""
    property string konto: ""
    property int minuten: 10

    /// Sendungen aus Home Assistant
    property var haSendungen: []
    /// Angekündigte Briefe (nur mit Home Assistant)
    property var briefe: []
    /// Brief-ID → data:-Adresse des Umschlagbilds
    property var bilder: ({})
    property var bekannteBriefe: ({})
    /// Direkt verfolgte Sendungen (der Besitzer speichert sie bei direktGeaendert)
    property var direkt: []
    /// Schlüssel der Anbieter: {dhl, upsId, upsGeheim, siebzehn, ship24, oeffentlich}
    property var schluessel: ({})
    /// Direkt hinzugefügte auch in Home Assistant eintragen
    property bool auchInHA: true
    /// Alle Sendungen (gleiche Nummer nur einmal)
    readonly property var sendungen: Logik.zusammenfuehren(haSendungen, direkt)
    /// Fehler der Anbieter bei der letzten direkten Abfrage
    property var anbieterFehler: ({})
    property var bekannt: ({})
    /// Nummer → an Home Assistant geschickter Stand (Abgleich zwischen den Geräten)
    property var gesendet: ({})
    property var konten: []
    property int version: 0
    property string fehler: ""
    property bool laedt: false
    property bool geladen: false
    /// Token abgelehnt: nicht weiter fragen (Home Assistant sperrt sonst die IP-Adresse)
    property bool abgelehnt: false

    readonly property string basis: Logik.adresse(adresse)
    readonly property bool eingerichtet: basis !== "" && token.trim() !== ""
    readonly property bool mehrereKonten: konten.length > 1
    /// Überhaupt etwas zu zeigen (Home Assistant oder direkt verfolgt)
    readonly property bool bereit: eingerichtet || direkt.length > 0

    signal neuerStand(var titel, var text, var id)
    signal meldung(string text)
    signal direktGeaendert(var liste)

    onBasisChanged: neuVerbinden()
    onTokenChanged: neuVerbinden()
    onKontoChanged: laden()

    function neuVerbinden() {
        abgelehnt = false;
        haSendungen = [];
        briefe = [];
        bilder = {};
        bekannteBriefe = {};
        geladen = !eingerichtet;
        verzoegert.restart();
    }

    /// Mitteilungen: Stand jeder Sendung mit dem zuletzt gesehenen vergleichen
    function pruefeMitteilungen() {
        var erstes = Object.keys(bekannt).length === 0;
        var neu = {};
        sendungen.forEach(function (s) {
            neu[s.id] = s;
            var m = erstes ? null : Logik.mitteilung(bekannt[s.id], s);
            if (m) neuerStand(m.titel, m.text, s.id);
        });
        bekannt = neu;
    }

    function direktSetzen(liste) {
        direkt = liste;
        direktGeaendert(liste);
        abgleichen();
    }

    /// Eigene Sendungen samt Stand an Home Assistant geben – so tauchen sie auf iPhone, Mac und anderen Rechnern auf
    function abgleichen() {
        if (!eingerichtet || !auchInHA || !geladen || abgelehnt) return;
        var offen = Logik.abgleich(haSendungen, direkt, gesendet);
        if (!offen.length) return;
        var g = Object.assign({}, gesendet), rest = offen.length;
        offen.forEach(function (d) {
            g[d.nummer] = d.signatur;
            anfrage("POST", "/api/briefankuendigung/sendung",
                    { nummer: d.nummer, dienst: d.dienst, name: d.name || d.absender || "", konto: konto, stand_info: Logik.standInfo(d) },
                    function () { if (--rest === 0) laden(); });
        });
        gesendet = g;
    }

    /// Direkt verfolgte Sendungen bei den Anbietern abfragen (offene, und zugestellte bis eine Stunde danach)
    function direktAktualisieren() {
        // Sendungen aus Home Assistant ohne Verlauf selbst mitverfolgen (z. B. DHL ohne Schlüssel in Home Assistant)
        var neu = [];
        haSendungen.slice(0, 30).forEach(function (s) {
            if (!s.ereignisse.length && !Logik.fertig(s) && s.nummer && Anbieter.namen(schluessel, s.dienst).length
                && !direkt.some(function (x) { return x.nummer === String(s.nummer).toUpperCase(); }))
                neu.push(Anbieter.neu(s.nummer, s.dienst, s.name || s.absender, s.ruecksendung));
        });
        if (neu.length) direktSetzen(direkt.concat(neu));
        var offen = direkt.filter(function (s) { return !Logik.fertig(s) || Date.now() - s.datum < 3600000; });
        offen.forEach(function (s) { einmalAbfragen(s); });
    }

    function einmalAbfragen(s) {
        if (!s.nummer) return;
        Anbieter.abfragen(schluessel, s.nummer, s.dienst).then(function (r) {
            var f = r.fehler;
            if (!r.spur && Anbieter.namen(schluessel, s.dienst).length === 0) f = { "–": S.t("Kein Anbieter für %1 eingerichtet.", s.dienstName) };
            anbieterFehler = f;
            if (!r.spur) return;
            var liste = direkt.slice(), i = liste.findIndex(function (x) { return x.nummer === s.nummer; });
            if (i < 0) liste.unshift(Anbieter.uebernehmen(Anbieter.neu(s.nummer, s.dienst, s.name, false), r.spur, r.quelle));
            else liste[i] = Anbieter.uebernehmen(liste[i], r.spur, r.quelle);
            direktSetzen(liste);
            pruefeMitteilungen();
        });
    }

    function fehlerText(status) {
        if (status === 401 || status === 403) return S.t("Zugriff verweigert – bitte den Token prüfen.");
        if (status === 404) return S.t("Die Integration „Briefankündigung“ fehlt in Home Assistant (HACS, ab Version 1.4).");
        if (status === 400) return S.t("Sendungsnummer oder Paketdienst nicht erkannt.");
        if (status === 405) return S.t("Dafür die Integration in Home Assistant aktualisieren.");
        if (status === 0) return S.t("Home Assistant ist nicht erreichbar (%1).", basis);
        return S.t("Fehler %1 von Home Assistant.", status);
    }

    function anfrage(methode, pfad, koerper, fertig) {
        if (!eingerichtet) return;
        var x = new XMLHttpRequest();
        x.open(methode, basis + pfad);
        x.setRequestHeader("Authorization", "Bearer " + token.trim());
        x.setRequestHeader("Content-Type", "application/json");
        x.timeout = 20000;
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            var ok = x.status >= 200 && x.status < 300;
            var j = null;
            try { j = JSON.parse(x.responseText); } catch (e) { j = null; }
            if (x.status === 401 || x.status === 403) abgelehnt = true;
            fertig(ok ? j : null, ok ? "" : fehlerText(x.status), x.status);
        };
        x.send(koerper ? JSON.stringify(koerper) : null);
    }

    // „Paket Tracker“ (parcel_tracker) in Home Assistant: dann kommen die Pakete von dort, Briefankündigung liefert nur Briefe
    property bool paketTracker: false
    property var ptSendungen: []

    function laden() {
        direktAktualisieren();
        if (!eingerichtet || abgelehnt) return;
        laedt = true;
        anfrage("GET", "/api/states", null, function (alle) {
            var da = !!alle && alle.some(function (z) { return z.entity_id === "sensor.pakete_heute"; });
            paketTracker = da;
            ptSendungen = da ? Logik.paketTrackerAus(alle) : [];
            ladenBriefe();
        });
    }

    function ladenBriefe() {
        anfrage("GET", "/api/briefankuendigung/briefe", null, function (j, text, status) {
            laedt = false;
            if (paketTracker && (status === 404 || !j)) {
                // nur Paket Tracker eingerichtet: Pakete von dort, keine Briefe
                haSendungen = ptSendungen; briefe = []; fehler = ""; geladen = true; pruefeMitteilungen(); direktAktualisieren();
                return;
            }
            if (text || !j) { fehler = text || S.t("Unerwartete Antwort von Home Assistant."); return; }
            var k = konto.trim().toLowerCase();
            var neu = Logik.sendungenAus(j).filter(function (s) { return !k || s.kontoId.toLowerCase() === k || s.kontoName.toLowerCase() === k; });
            konten = j.konten || [];
            version = j.version || 1;
            haSendungen = paketTracker ? ptSendungen : neu;
            var nb = Logik.briefeAus(j).filter(function (b) { return !k || b.kontoId.toLowerCase() === k || b.kontoName.toLowerCase() === k; });
            // neue Briefe von heute melden (nicht beim ersten Laden)
            if (geladen) {
                var heute = new Date().toDateString();
                var neueBriefe = nb.filter(function (b) { return !bekannteBriefe[b.id] && !b.erledigt && new Date(b.datum).toDateString() === heute; });
                if (neueBriefe.length)
                    neuerStand((neueBriefe.some(function (b) { return b.wichtig; }) ? "⚠️ " : "✉️ ")
                               + (neueBriefe.length === 1 ? S.t("Brief angekündigt") : S.t("%1 angekündigt", Logik.briefeAnzahl(neueBriefe.length))),
                               neueBriefe.map(function (b) { return (b.wichtig ? "⚠️ " : "") + Logik.briefTitel(b); }).join(", "), neueBriefe[0].id);
            }
            var bk = {};
            nb.forEach(function (b) { bk[b.id] = true; });
            bekannteBriefe = bk;
            briefe = nb;
            nb.slice(0, 30).forEach(function (b) { if (b.bild && !bilder[b.id]) bildLaden(b.id); });
            fehler = "";
            geladen = true;
            pruefeMitteilungen();
            abgleichen();
            direktAktualisieren();
        });
    }

    /// Sendung verfolgen: direkt (auf diesem Rechner) und – wenn eingerichtet – auch in Home Assistant.
    /// fertig(fehlertext) – "" bei Erfolg
    function hinzufuegen(nummer, dienst, name, fertig, ruecksendung) {
        var s = Anbieter.neu(nummer, dienst, name, ruecksendung);
        if (!direkt.some(function (x) { return x.nummer === s.nummer; })) direktSetzen([s].concat(direkt));
        einmalAbfragen(s);
        if (!eingerichtet || !auchInHA) { fertig(""); return; }
        if (paketTracker) {
            var d = { number: nummer, carrier: ["dhl", "dpd", "gls", "hermes", "ups"].indexOf(dienst) >= 0 ? dienst : "auto" };
            if (name) d.name = name;
            anfrage("POST", "/api/services/parcel_tracker/add_parcel", d, function (j, text) { if (!text) laden(); fertig(text); });
            return;
        }
        anfrage("POST", "/api/briefankuendigung/sendung", { nummer: nummer, dienst: dienst, name: name, konto: konto }, function (j, text) {
            if (!text) laden();
            fertig(text);
        });
    }

    function bildLaden(id) {
        var x = new XMLHttpRequest();
        x.open("GET", basis + "/api/briefankuendigung/bild/" + id);
        x.setRequestHeader("Authorization", "Bearer " + token.trim());
        x.responseType = "arraybuffer";
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE || x.status !== 200 || !x.response) return;
            var neu = Object.assign({}, bilder);
            neu[id] = Logik.bildAdresse(new Uint8Array(x.response));
            bilder = neu;
        };
        x.send();
    }

    function brief(id) { return briefe.find(function (b) { return b.id === id; }) || null; }

    /// Brief als angekommen markieren (gilt über Home Assistant auf allen Geräten)
    function briefErledigt(id, ja) {
        briefe = briefe.map(function (b) { return b.id === id ? Object.assign({}, b, { erledigt: ja }) : b; });
        anfrage("POST", "/api/briefankuendigung/erledigt", { id: id, erledigt: ja }, function (j, text) { if (text) meldung(text); laden(); });
    }

    function sendung(id) { return sendungen.find(function (s) { return s.id === id; }) || null; }

    function umbenennen(id, name) {
        var s = sendung(id);
        direktSetzen(direkt.map(function (x) { return x.id === id || (s && x.nummer === s.nummer) ? Object.assign({}, x, { name: name }) : x; }));
        var ptn = Logik.paketTrackerNummer(id);
        if (ptn) { anfrage("POST", "/api/services/parcel_tracker/rename_parcel", { number: ptn, name: name }, function (j, text) { if (text) meldung(text); laden(); }); return; }
        if (s && s.quelle !== "direkt")
            anfrage("POST", "/api/briefankuendigung/sendung/name", { id: id, name: name }, function (j, text) { if (text) meldung(text); laden(); });
    }

    function entfernen(id) {
        var s = sendung(id);
        direktSetzen(direkt.filter(function (x) { return x.id !== id && !(s && s.nummer && x.nummer === s.nummer); }));
        haSendungen = haSendungen.filter(function (x) { return x.id !== id || !x.manuell; });
        var ptn = Logik.paketTrackerNummer(id);
        if (ptn) { anfrage("POST", "/api/services/parcel_tracker/remove_parcel", { number: ptn }, function (j, text) { if (text) meldung(text); laden(); }); return; }
        if (s && s.quelle !== "direkt")
            anfrage("POST", "/api/briefankuendigung/sendung/entfernen", { id: id }, function (j, text) { if (text) meldung(text); laden(); });
    }

    function erledigt(id, ja) {
        var s = sendung(id);
        if (s && s.quelle === "direkt") {
            direktSetzen(direkt.map(function (x) { return x.id === id ? Object.assign({}, x, { erledigt: ja }) : x; }));
            return;
        }
        haSendungen = haSendungen.map(function (x) { return x.id === id ? Object.assign({}, x, { erledigt: ja }) : x; });
        var ptn = Logik.paketTrackerNummer(id);
        if (ptn) { if (ja) anfrage("POST", "/api/services/parcel_tracker/mark_delivered", { number: ptn }, function (j, text) { if (text) meldung(text); laden(); }); return; }
        anfrage("POST", "/api/briefankuendigung/erledigt", { id: id, erledigt: ja }, function (j, text) { if (text) meldung(text); laden(); });
    }

    function jetztNachsehen() {
        if (paketTracker) anfrage("POST", "/api/services/parcel_tracker/refresh", {}, function () {});
        anfrage("POST", "/api/briefankuendigung/abrufen" + (konto ? "?konto=" + encodeURIComponent(konto) : ""), {}, function (j, text) {
            if (text) { meldung(text); return; }
            nachladen.zaehler = 0;
            nachladen.restart();
        });
    }

    property Timer verzoegert: Timer { interval: 500; onTriggered: ha.laden() }
    property Timer regelmaessig: Timer { interval: Math.max(1, ha.minuten) * 60000; running: ha.bereit; repeat: true; onTriggered: ha.laden() }
    property Timer nachladen: Timer {
        property int zaehler: 0
        interval: 5000; repeat: true
        onTriggered: { ha.laden(); if (++zaehler >= 4) stop(); }
    }
}
