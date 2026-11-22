// Prüft linux/gemeinsam/logik.js ohne Qt: node linux/test/logik-test.mjs
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const ordner = new URL('../gemeinsam/', import.meta.url);
const lies = (n) => fs.readFileSync(new URL(n, ordner), 'utf8').replace(/^\.(pragma|import).*$/gm, '');
function laden(sprache) {
  const ctx = { Qt: { locale: () => ({ name: sprache }) }, console };
  vm.createContext(ctx);
  vm.runInContext(lies('uebersetzung.js') + '\nvar U = { EN: EN };\n' + lies('sprache.js') + '\nvar S = { t: t };\n' + lies('logik.js')
    + '\nvar Logik = { t: t, dienst: dienst, stufe: stufe };\nvar A = (function () {\n' + lies('anbieter.js')
    + '\nreturn { kette: kette, namen: namen, dhlOeffentlich: dhlOeffentlich, standAusText: standAusText, BESCHREIBUNG: BESCHREIBUNG };\n})();', ctx);
  return ctx;
}
const L = laden('de_DE');
const jetzt = new Date(2026, 9, 21, 9).getTime();
const antwort = { briefe: [
  { id: 'p1', datum: jetzt, art: 'paket', absender: 'OTTO', sendung: 'H1002345678901234567', dienst: 'hermes', erwartet: '2026-10-23', zeitfenster: '10:00–13:00',
    ereignisse: [{ zeit: '2026-10-20T18:00:00+02:00', text: 'Im Verteilzentrum', ort: 'Ketzin' }] },
  { id: 'p2', datum: jetzt, art: 'paket', absender: 'Zalando', dienst: 'dpd', stand: 'heute' },
  { id: 'p3', datum: jetzt, art: 'paket', absender: 'Kindle', name: 'Geschenk Oma', dienst: 'amazon', erwartet: '2026-10-22', kundenkonto: 'Johanna' },
  { id: 'p4', datum: jetzt, art: 'paket', absender: 'Alt', stand: 'zugestellt' },
  { id: 'p5', datum: jetzt, art: 'paket', absender: 'Kaffee', stand: 'abholbereit', dienst: 'gls' },
  { id: 'b1', datum: jetzt, art: 'brief', absender: 'AOK' },
] };
const s = L.sendungenAus(antwort);
assert.equal(s.length, 5);
const g = L.gruppen(s, jetzt, 14);
assert.equal(JSON.stringify(g.heute.map((x) => x.id)), JSON.stringify(['p2', 'p5']));
assert.equal(JSON.stringify(g.unterwegs.map((x) => x.id)), JSON.stringify(['p3', 'p1']));
assert.equal(JSON.stringify(g.zugestellt.map((x) => x.id)), JSON.stringify(['p4']));
assert.equal(L.standText(s[0], jetzt), 'voraussichtlich Fr 23.10., 10:00–13:00');
assert.equal(L.zeile(s[2], jetzt, false), 'kommt morgen · Johanna');
assert.equal(L.titel(s[2]), 'Geschenk Oma');
assert.equal(L.stufe(s[0]), 2);
assert.equal(L.kopfTitel(g.aktiv), '4 Pakete unterwegs');
assert.equal(L.dienstVonNummer('1Z999AA10123456784'), 'ups');
assert.equal(L.dienstVonNummer('01234567890123'), '');
assert.equal(L.nummerIn('Sendungsnummer: 00340434161094015902.'), '00340434161094015902');
assert.equal(L.verfolgenAdresse({ dienst: 'gls', nummer: '123' }), 'https://gls-group.com/DE/de/paketverfolgung?match=123');
assert.equal(L.mitteilung(s[0], Object.assign({}, s[0], { stand: 'heute' })).titel, '📦 Kommt heute');
assert.equal(L.mitteilung(s[0], s[0]), null);
assert.equal(L.adresse('homeassistant.local:8123/'), 'http://homeassistant.local:8123');
const E = laden('en_GB');
assert.equal(E.standText(E.sendungenAus(antwort)[2], jetzt), 'arrives tomorrow');
// Anbieter
const A = L.A;
assert.equal(JSON.stringify(A.namen({ oeffentlich: true }, 'dhl')), JSON.stringify(['DHL (ohne Schlüssel)']));
assert.equal(JSON.stringify(A.namen({ dhl: 'k', siebzehn: 'x', aus: ['17TRACK'] }, 'dhl')), JSON.stringify(['DHL', 'DHL (ohne Schlüssel)']));
assert.equal(JSON.stringify(A.namen({ oeffentlich: false }, 'hermes')), '[]');
const dp = A.dhlOeffentlich({ sendungsdetails: { istZugestellt: true, sendungsverlauf: { status: 'Abholung aus Packstation', events: [
  { datum: '2026-10-19T14:13:52+02:00', status: 'Die Sendung liegt in der Packstation zur Abholung bereit.' },
  { datum: '2026-10-21T15:29:34+02:00', status: 'Abholung aus Packstation' }] } } });
assert.equal(dp.stand, 'zugestellt');
assert.equal(dp.ereignisse[0].text, 'Abholung aus Packstation');
assert.equal(A.standAusText('Die Sendung konnte nicht zugestellt werden und wird in eine Packstation gebracht.'), 'unterwegs');
assert.equal(A.standAusText('Die Sendung liegt in der Packstation zur Abholung bereit.'), 'abholbereit');
assert.equal(A.BESCHREIBUNG.length, 7);
// eigener Stand gewinnt beim Zusammenführen
const ha = L.sendungenAus({ briefe: [{ id: 'x', datum: jetzt, art: 'paket', name: 'Test', sendung: '00340434161094015902', dienst: 'dhl' }] });
const m = L.zusammenfuehren(ha, [{ id: 'd', datum: jetzt, nummer: '00340434161094015902', dienst: 'dhl', stand: 'zugestellt', ereignisse: [{ zeit: jetzt, text: 'Abgeholt' }], quelle: 'direkt' }]);
assert.equal(m.length, 1); assert.equal(m[0].id, 'x'); assert.equal(m[0].stand, 'zugestellt');
// Briefe
const br = L.briefeAus({ briefe: [
  { id: 'b1', datum: jetzt - 3600e3, art: 'brief', absender: 'AOK', bild: true },
  { id: 'b2', datum: jetzt - 1800e3, art: 'brief', absender: 'Finanzamt', wichtig: true },
  { id: 'b3', datum: jetzt - 30 * 3600e3, art: 'brief', absender: '' },
  { id: 'b4', datum: jetzt - 8 * 86400e3, art: 'brief', absender: 'Alt' },
  { id: 'p9', datum: jetzt, art: 'paket', absender: 'kein Brief' }] });
assert.equal(br.length, 4);
const bg = L.briefGruppen(br, jetzt, 5);
assert.equal(JSON.stringify(bg.heute.map((x) => x.id)), JSON.stringify(['b2', 'b1']), 'wichtige zuerst');
assert.equal(JSON.stringify(bg.unterwegs.map((x) => x.id)), JSON.stringify(['b3']));
assert.equal(JSON.stringify(bg.angekommen.map((x) => x.id)), JSON.stringify(['b4']));
assert.equal(L.briefTitel(br[2]), 'Absender unbekannt');
assert.equal(L.briefZeile(br[0], jetzt, false), 'angekündigt heute');
assert.equal(L.postTitel(bg.offen, g.aktiv), '3 Briefe, 4 Pakete unterwegs');
assert.equal(L.postTitel([], []), 'Keine Post unterwegs');
assert.ok(L.bildAdresse(new Uint8Array([0x89, 0x50, 1, 2])).startsWith('data:image/png;base64,iVA'));
// Abholen und Rückgabe
const ab = L.sendungenAus({ briefe: [
  { id: 'a1', datum: jetzt, art: 'paket', absender: 'Kaffee', stand: 'abholbereit', dienst: 'dhl', abholcode: '482913', abholort: 'Packstation 123' },
  { id: 'a2', datum: jetzt - 6 * 86400000, art: 'paket', absender: 'Zalando SE', stand: 'zugestellt', dienst: 'dpd' },
  { id: 'a3', datum: jetzt, art: 'paket', absender: 'Fahrradladen', stand: 'zugestellt', dienst: 'ups', ruecksendefrist: '2026-10-22' },
  { id: 'a4', datum: jetzt, art: 'paket', absender: 'Fahrradladen', stand: 'zugestellt', dienst: 'ups' },
] });
assert.ok(L.zumAbholen(ab[0]));
assert.equal(L.zeile(ab[0], jetzt, false), 'Abholcode 482913 · Packstation 123');
assert.ok(L.routeAdresse(ab[0]).includes('Packstation%20123'));
assert.equal(new Date(L.rueckgabeBis(ab[1])).getDate(), 23, 'Zalando 100 Tage');
assert.ok(L.rueckgabeOffen(ab[1], jetzt));
assert.equal(L.kurzTag(L.rueckgabeBis(ab[2]), jetzt), 'morgen');
assert.equal(L.rueckgabeBis(ab[3]), 0, 'unbekannter Shop');
assert.equal(L.mitteilung(Object.assign({}, ab[0], { stand: 'unterwegs' }), ab[0]).text, 'Kaffee (DHL) – Abholcode 482913 · Packstation 123');
// Abgleich mit Home Assistant
const ha1 = L.sendungenAus({ briefe: [{ id: 'h1', datum: jetzt, art: 'paket', sendung: 'AAA111222', dienst: 'dhl', stand: 'unterwegs' }] });
const dir = [
  { nummer: 'AAA111222', dienst: 'dhl', stand: 'zugestellt', ereignisse: [{ zeit: jetzt, text: 'Zugestellt', ort: 'Hamburg' }], erledigt: false },
  { nummer: 'BBB333444', dienst: 'dhl', stand: 'unterwegs', ereignisse: [], erledigt: false },
  { nummer: 'AAA111222X', dienst: 'dhl', stand: 'unterwegs', ereignisse: [], erledigt: false },
];
const gesendet = {};
const ab1 = L.abgleich(ha1, dir.slice(0, 2), gesendet);
assert.deepEqual(ab1.map((d) => d.nummer), ['AAA111222', 'BBB333444'], 'neuerer Stand und unbekannte Sendung');
ab1.forEach((d) => { gesendet[d.nummer] = d.signatur; });
assert.equal(L.abgleich(ha1, dir.slice(0, 2), gesendet).length, 0, 'nicht zweimal dasselbe');
const ha2 = L.sendungenAus({ briefe: [{ id: 'h1', datum: jetzt, art: 'paket', sendung: 'AAA111222X', dienst: 'dhl', stand: 'zugestellt' }] });
assert.equal(L.abgleich(ha2, [dir[2]], {}).length, 0, 'Home Assistant weiß schon mehr');
const si = L.standInfo(dir[0]);
assert.equal(si.stand, 'zugestellt');
assert.ok(si.ereignisse[0].zeit.startsWith('2026-10-21'));
console.log('logik.js: alle Prüfungen bestanden');

// Paket Tracker (parcel_tracker)
{
  const z = [
    { entity_id: "sensor.paket_00340434", state: "out_for_delivery", last_changed: "2026-11-22T08:00:00+00:00",
      attributes: { carrier: "dhl", carrier_name: "DHL", number: "00340434", name: "Druckerpatronen", eta_from: "10:00", eta_to: "12:00", events: [{ timestamp: "2026-11-22T07:00:00+00:00", text: "Im Fahrzeug", location: "Hamburg" }] } },
    { entity_id: "sensor.paket_tracker_17track_kontingent", state: "90", attributes: {} },
    { entity_id: "sensor.paket_amz1", state: "awaiting_pickup", attributes: { carrier: "amazon", number: "amz1", pickup_point: "Packstation 101" } },
  ];
  const s = L.paketTrackerAus(z);
  assert.ok(s.length === 2, "Paket Tracker: zwei Pakete");
  assert.ok(s.find((x) => x.dienst === "dhl").stand === "heute" && s.find((x) => x.dienst === "dhl").zeitfenster === "10:00–12:00", "Paket Tracker: Stand und Zeitfenster");
  assert.ok(s.find((x) => x.dienst === "amazon").stand === "abholbereit", "Paket Tracker: abholbereit");
  assert.ok(L.paketTrackerNummer("pt:00340434") === "00340434" && L.paketTrackerNummer("x") === "", "Paket Tracker: Nummer");
}
