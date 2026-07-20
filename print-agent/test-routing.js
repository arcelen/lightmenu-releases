/**
 * Multi-printer routing logic test.
 *
 * Faithfully replicates the decision the Station makes for a kitchen ticket:
 *   • the /print handler: kitchen ticket + stations configured → printKitchenRouted,
 *     else print once to the default printer.
 *   • printKitchenRouted: group items by menu_category_id → each category's
 *     printer; item with no category id → default; category with no station → drop.
 *
 * Simulates two printers so the split can be asserted without hardware.
 * Run: node test-routing.js
 */

// ── replica of main.js printersForCategory + the /print routing decision ──
function printersForCategory(routingCache, catId) {
  if (!catId) return [];
  const key = String(catId);
  return routingCache.filter(r => String(r.menu_category_id) === key);
}

// Returns { sends: [{printerNumber|null, items:[...]}], dropped:[...] }
function route(items, routingCache) {
  const stationsConfigured = routingCache.length > 0;

  // /print handler: no stations → one ticket to the default printer.
  if (!stationsConfigured) {
    return { sends: [{ printerNumber: null, items: items.slice() }], dropped: [] };
  }

  // printKitchenRouted: split by category.
  const groups = new Map();
  const dropped = [];
  for (const it of items) {
    const catId = it.menu_category_id || it.category_id || null;
    const routes = printersForCategory(routingCache, catId);
    if (routes.length) {
      for (const r of routes) {
        const key = 'p:' + r.printer_config_id;
        if (!groups.has(key)) groups.set(key, { printerNumber: r.printer_number, items: [] });
        groups.get(key).items.push(it);
      }
    } else if (!catId) {
      if (!groups.has('default')) groups.set('default', { printerNumber: null, items: [] });
      groups.get('default').items.push(it);
    } else {
      dropped.push(it);
    }
  }
  return { sends: [...groups.values()], dropped };
}

// ── test harness ──
let pass = 0, fail = 0;
// Canonicalize object key order so the comparison checks WHERE items landed,
// not the incidental order the printer groups were built in.
function canon(o) {
  if (Array.isArray(o)) return o;
  return Object.keys(o).sort().reduce((acc, k) => (acc[k] = o[k], acc), {});
}
function eq(actual, expected, label) {
  const a = JSON.stringify(canon(actual)), e = JSON.stringify(canon(expected));
  if (a === e) { pass++; console.log('  ✓ ' + label); }
  else { fail++; console.log('  ✗ ' + label + '\n      expected ' + e + '\n      got      ' + a); }
}
// name → which printer number each item landed on (or 'DROP')
function landing(items, cache) {
  const { sends, dropped } = route(items, cache);
  const map = {};
  for (const s of sends) for (const it of s.items) {
    (map[it.name] ||= []).push(s.printerNumber === null ? 'default' : s.printerNumber);
  }
  for (const it of dropped) (map[it.name] ||= []).push('DROP');
  return map;
}

const CAT = { drinks: 'c-drinks', food: 'c-food', dessert: 'c-dessert' };
// Two printers: #1 = bar (drinks), #2 = kitchen (food).
const twoPrinters = [
  { menu_category_id: CAT.drinks, printer_config_id: 'p1', printer_number: 1 },
  { menu_category_id: CAT.food,   printer_config_id: 'p2', printer_number: 2 },
];

console.log('1. Two printers — drinks→#1, food→#2:');
eq(landing([
  { name: 'Coke',   menu_category_id: CAT.drinks },
  { name: 'Burger', menu_category_id: CAT.food },
  { name: 'Beer',   menu_category_id: CAT.drinks },
], twoPrinters), { Coke: [1], Burger: [2], Beer: [1] }, 'each item routes to its category\'s printer');

console.log('2. Unassigned category (dessert on no station) → dropped:');
eq(landing([
  { name: 'Burger', menu_category_id: CAT.food },
  { name: 'Cake',   menu_category_id: CAT.dessert },
], twoPrinters), { Burger: [2], Cake: ['DROP'] }, 'known-but-unassigned category does not print');

console.log('3. Missing category id → default printer (safety net):');
eq(landing([
  { name: 'Mystery' }, // no menu_category_id
], twoPrinters), { Mystery: ['default'] }, 'item with no category id is never dropped');

console.log('4. Category assigned to BOTH printers → prints on both:');
const bothCache = [
  { menu_category_id: CAT.food, printer_config_id: 'p1', printer_number: 1 },
  { menu_category_id: CAT.food, printer_config_id: 'p2', printer_number: 2 },
];
eq(landing([{ name: 'Burger', menu_category_id: CAT.food }], bothCache),
  { Burger: [1, 2] }, 'a category on two printers prints on both');

console.log('5. No stations configured → everything to the default printer:');
eq(landing([
  { name: 'Coke',   menu_category_id: CAT.drinks },
  { name: 'Burger', menu_category_id: CAT.food },
], []), { Coke: ['default'], Burger: ['default'] }, 'backward compatible with single printer');

console.log('6. One printer, some categories assigned, others not:');
const onePrinter = [{ menu_category_id: CAT.food, printer_config_id: 'p2', printer_number: 2 }];
eq(landing([
  { name: 'Burger', menu_category_id: CAT.food },
  { name: 'Coke',   menu_category_id: CAT.drinks },
], onePrinter), { Burger: [2], Coke: ['DROP'] }, 'once a station exists, only assigned categories print');

console.log('\n' + (fail === 0 ? '✅ ALL ' + pass + ' ROUTING CASES PASSED' : '❌ ' + fail + ' FAILED, ' + pass + ' passed'));
process.exit(fail === 0 ? 0 : 1);
