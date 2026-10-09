// Offline address suggestions: native <datalist>s for country, city and state/region.
// Any input named country / ship_country gets ISO 3166-1 alpha-2 suggestions; city and region
// inputs in the same form get suggestions for whichever country is currently entered.
(() => {
  const COUNTRIES = "AD Andorra|AE United Arab Emirates|AF Afghanistan|AG Antigua and Barbuda|AI Anguilla|AL Albania|AM Armenia|AO Angola|AQ Antarctica|AR Argentina|AS American Samoa|AT Austria|AU Australia|AW Aruba|AX Åland Islands|AZ Azerbaijan|BA Bosnia and Herzegovina|BB Barbados|BD Bangladesh|BE Belgium|BF Burkina Faso|BG Bulgaria|BH Bahrain|BI Burundi|BJ Benin|BL Saint Barthélemy|BM Bermuda|BN Brunei|BO Bolivia|BQ Caribbean Netherlands|BR Brazil|BS Bahamas|BT Bhutan|BV Bouvet Island|BW Botswana|BY Belarus|BZ Belize|CA Canada|CC Cocos (Keeling) Islands|CD Congo (DRC)|CF Central African Republic|CG Congo (Republic)|CH Switzerland|CI Côte d’Ivoire|CK Cook Islands|CL Chile|CM Cameroon|CN China|CO Colombia|CR Costa Rica|CU Cuba|CV Cape Verde|CW Curaçao|CX Christmas Island|CY Cyprus|CZ Czechia|DE Germany|DJ Djibouti|DK Denmark|DM Dominica|DO Dominican Republic|DZ Algeria|EC Ecuador|EE Estonia|EG Egypt|EH Western Sahara|ER Eritrea|ES Spain|ET Ethiopia|FI Finland|FJ Fiji|FK Falkland Islands|FM Micronesia|FO Faroe Islands|FR France|GA Gabon|GB United Kingdom|GD Grenada|GE Georgia|GF French Guiana|GG Guernsey|GH Ghana|GI Gibraltar|GL Greenland|GM Gambia|GN Guinea|GP Guadeloupe|GQ Equatorial Guinea|GR Greece|GS South Georgia & South Sandwich Islands|GT Guatemala|GU Guam|GW Guinea-Bissau|GY Guyana|HK Hong Kong|HM Heard & McDonald Islands|HN Honduras|HR Croatia|HT Haiti|HU Hungary|ID Indonesia|IE Ireland|IL Israel|IM Isle of Man|IN India|IO British Indian Ocean Territory|IQ Iraq|IR Iran|IS Iceland|IT Italy|JE Jersey|JM Jamaica|JO Jordan|JP Japan|KE Kenya|KG Kyrgyzstan|KH Cambodia|KI Kiribati|KM Comoros|KN Saint Kitts and Nevis|KP North Korea|KR South Korea|KW Kuwait|KY Cayman Islands|KZ Kazakhstan|LA Laos|LB Lebanon|LC Saint Lucia|LI Liechtenstein|LK Sri Lanka|LR Liberia|LS Lesotho|LT Lithuania|LU Luxembourg|LV Latvia|LY Libya|MA Morocco|MC Monaco|MD Moldova|ME Montenegro|MF Saint Martin|MG Madagascar|MH Marshall Islands|MK North Macedonia|ML Mali|MM Myanmar|MN Mongolia|MO Macao|MP Northern Mariana Islands|MQ Martinique|MR Mauritania|MS Montserrat|MT Malta|MU Mauritius|MV Maldives|MW Malawi|MX Mexico|MY Malaysia|MZ Mozambique|NA Namibia|NC New Caledonia|NE Niger|NF Norfolk Island|NG Nigeria|NI Nicaragua|NL Netherlands|NO Norway|NP Nepal|NR Nauru|NU Niue|NZ New Zealand|OM Oman|PA Panama|PE Peru|PF French Polynesia|PG Papua New Guinea|PH Philippines|PK Pakistan|PL Poland|PM Saint Pierre and Miquelon|PN Pitcairn Islands|PR Puerto Rico|PS Palestine|PT Portugal|PW Palau|PY Paraguay|QA Qatar|RE Réunion|RO Romania|RS Serbia|RU Russia|RW Rwanda|SA Saudi Arabia|SB Solomon Islands|SC Seychelles|SD Sudan|SE Sweden|SG Singapore|SH Saint Helena|SI Slovenia|SJ Svalbard and Jan Mayen|SK Slovakia|SL Sierra Leone|SM San Marino|SN Senegal|SO Somalia|SR Suriname|SS South Sudan|ST São Tomé and Príncipe|SV El Salvador|SX Sint Maarten|SY Syria|SZ Eswatini|TC Turks and Caicos Islands|TD Chad|TF French Southern Territories|TG Togo|TH Thailand|TJ Tajikistan|TK Tokelau|TL Timor-Leste|TM Turkmenistan|TN Tunisia|TO Tonga|TR Türkiye|TT Trinidad and Tobago|TV Tuvalu|TW Taiwan|TZ Tanzania|UA Ukraine|UG Uganda|UM U.S. Outlying Islands|US United States|UY Uruguay|UZ Uzbekistan|VA Vatican City|VC Saint Vincent and the Grenadines|VE Venezuela|VG British Virgin Islands|VI U.S. Virgin Islands|VN Vietnam|VU Vanuatu|WF Wallis and Futuna|WS Samoa|YE Yemen|YT Mayotte|ZA South Africa|ZM Zambia|ZW Zimbabwe";

  const CITIES = {
    SG: "Singapore",
    US: "New York|Los Angeles|Chicago|Houston|Phoenix|Philadelphia|San Antonio|San Diego|Dallas|San Jose|Austin|Jacksonville|San Francisco|Columbus|Seattle|Denver|Washington|Boston|Nashville|Portland|Las Vegas|Atlanta|Miami|Minneapolis|Honolulu",
    GB: "London|Birmingham|Manchester|Glasgow|Liverpool|Leeds|Sheffield|Edinburgh|Bristol|Cardiff|Belfast|Leicester|Nottingham|Newcastle upon Tyne|Southampton|Brighton|Oxford|Cambridge|Aberdeen|York",
    MY: "Kuala Lumpur|Petaling Jaya|Shah Alam|Subang Jaya|Johor Bahru|George Town|Ipoh|Kuching|Kota Kinabalu|Malacca City|Seremban|Kuantan|Kota Bharu|Alor Setar|Putrajaya|Cyberjaya|Klang|Miri",
    ID: "Jakarta|Surabaya|Bandung|Medan|Bekasi|Tangerang|Depok|Semarang|Palembang|Makassar|Bogor|Batam|Denpasar|Yogyakarta|Malang|Pekanbaru|Balikpapan|Manado",
    TH: "Bangkok|Nonthaburi|Chiang Mai|Phuket|Pattaya|Hat Yai|Nakhon Ratchasima|Khon Kaen|Udon Thani|Chiang Rai|Hua Hin|Krabi|Samut Prakan|Pak Kret|Surat Thani",
    PH: "Manila|Quezon City|Makati|Taguig|Pasig|Cebu City|Davao City|Caloocan|Mandaluyong|Parañaque|Las Piñas|Antipolo|Zamboanga City|Cagayan de Oro|Iloilo City|Baguio|Bacolod",
    VN: "Ho Chi Minh City|Hanoi|Da Nang|Haiphong|Can Tho|Bien Hoa|Nha Trang|Hue|Vung Tau|Buon Ma Thuot|Thu Duc|Da Lat|Quy Nhon|Ha Long",
    HK: "Hong Kong|Kowloon|Central|Wan Chai|Causeway Bay|Tsim Sha Tsui|Mong Kok|Sha Tin|Tsuen Wan|Tuen Mun|Yuen Long|Tai Po|Kwun Tong|Sai Kung|Lantau Island",
    JP: "Tokyo|Yokohama|Osaka|Nagoya|Sapporo|Fukuoka|Kobe|Kawasaki|Kyoto|Saitama|Hiroshima|Sendai|Chiba|Kitakyushu|Sakai|Niigata|Hamamatsu|Kumamoto|Okayama|Naha",
    KR: "Seoul|Busan|Incheon|Daegu|Daejeon|Gwangju|Suwon|Ulsan|Changwon|Goyang|Yongin|Seongnam|Bucheon|Cheongju|Jeonju|Jeju City",
    CN: "Shanghai|Beijing|Shenzhen|Guangzhou|Chengdu|Chongqing|Tianjin|Wuhan|Hangzhou|Xi'an|Nanjing|Suzhou|Zhengzhou|Changsha|Shenyang|Qingdao|Dongguan|Xiamen|Kunming|Dalian",
    TW: "Taipei|New Taipei|Taichung|Kaohsiung|Taoyuan|Tainan|Hsinchu|Keelung|Chiayi|Changhua|Pingtung|Yilan|Hualien",
    AU: "Sydney|Melbourne|Brisbane|Perth|Adelaide|Gold Coast|Canberra|Newcastle|Sunshine Coast|Wollongong|Hobart|Geelong|Townsville|Cairns|Darwin|Toowoomba|Ballarat|Bendigo|Launceston",
    NZ: "Auckland|Wellington|Christchurch|Hamilton|Tauranga|Dunedin|Lower Hutt|Palmerston North|Napier|Nelson|Rotorua|New Plymouth|Whangārei|Invercargill|Queenstown",
    IN: "Mumbai|Delhi|New Delhi|Bengaluru|Hyderabad|Ahmedabad|Chennai|Kolkata|Pune|Surat|Jaipur|Lucknow|Kanpur|Nagpur|Indore|Bhopal|Visakhapatnam|Patna|Vadodara|Gurugram|Noida|Kochi|Chandigarh|Coimbatore",
    CA: "Toronto|Montreal|Vancouver|Calgary|Edmonton|Ottawa|Winnipeg|Quebec City|Hamilton|Kitchener|London|Victoria|Halifax|Oshawa|Windsor|Saskatoon|Regina|St. John's|Mississauga|Brampton",
    DE: "Berlin|Hamburg|Munich|Cologne|Frankfurt am Main|Stuttgart|Düsseldorf|Leipzig|Dortmund|Essen|Bremen|Dresden|Hanover|Nuremberg|Duisburg|Bochum|Bonn|Münster|Mannheim|Karlsruhe",
    FR: "Paris|Marseille|Lyon|Toulouse|Nice|Nantes|Montpellier|Strasbourg|Bordeaux|Lille|Rennes|Reims|Toulon|Saint-Étienne|Le Havre|Grenoble|Dijon|Angers|Nîmes|Aix-en-Provence",
    NL: "Amsterdam|Rotterdam|The Hague|Utrecht|Eindhoven|Groningen|Tilburg|Almere|Breda|Nijmegen|Apeldoorn|Haarlem|Arnhem|Enschede|Amersfoort|Zaanstad|'s-Hertogenbosch|Maastricht|Leiden|Delft",
    AE: "Dubai|Abu Dhabi|Sharjah|Al Ain|Ajman|Ras Al Khaimah|Fujairah|Umm Al Quwain|Khor Fakkan|Dibba",
    IE: "Dublin|Cork|Limerick|Galway|Waterford|Drogheda|Kilkenny|Sligo|Athlone",
    ES: "Madrid|Barcelona|Valencia|Seville|Zaragoza|Málaga|Murcia|Palma|Las Palmas|Bilbao|Alicante|Córdoba|Valladolid|Granada|San Sebastián",
    IT: "Rome|Milan|Naples|Turin|Palermo|Genoa|Bologna|Florence|Bari|Catania|Venice|Verona|Padua|Trieste|Brescia",
    CH: "Zurich|Geneva|Basel|Lausanne|Bern|Winterthur|Lucerne|St. Gallen|Lugano",
    BR: "São Paulo|Rio de Janeiro|Brasília|Salvador|Fortaleza|Belo Horizonte|Manaus|Curitiba|Recife|Porto Alegre|Goiânia|Belém|Campinas|Florianópolis",
    MX: "Mexico City|Guadalajara|Monterrey|Puebla|Tijuana|León|Juárez|Zapopan|Mérida|Cancún|Querétaro|San Luis Potosí|Aguascalientes|Toluca",
  };

  const GLOBAL_CITIES = "Singapore|New York|London|Tokyo|Hong Kong|Paris|Sydney|Los Angeles|San Francisco|Toronto|Dubai|Shanghai|Seoul|Kuala Lumpur|Bangkok|Jakarta|Manila|Taipei|Mumbai|Berlin|Amsterdam|Melbourne|Auckland|Ho Chi Minh City|Chicago";

  const REGIONS = {
    US: "AL|AK|AZ|AR|CA|CO|CT|DE|DC|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|PR|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY",
    US_LABELS: "Alabama|Alaska|Arizona|Arkansas|California|Colorado|Connecticut|Delaware|District of Columbia|Florida|Georgia|Hawaii|Idaho|Illinois|Indiana|Iowa|Kansas|Kentucky|Louisiana|Maine|Maryland|Massachusetts|Michigan|Minnesota|Mississippi|Missouri|Montana|Nebraska|Nevada|New Hampshire|New Jersey|New Mexico|New York|North Carolina|North Dakota|Ohio|Oklahoma|Oregon|Pennsylvania|Puerto Rico|Rhode Island|South Carolina|South Dakota|Tennessee|Texas|Utah|Vermont|Virginia|Washington|West Virginia|Wisconsin|Wyoming",
    AU: "NSW New South Wales|VIC Victoria|QLD Queensland|WA Western Australia|SA South Australia|TAS Tasmania|ACT Australian Capital Territory|NT Northern Territory",
    CA: "AB Alberta|BC British Columbia|MB Manitoba|NB New Brunswick|NL Newfoundland and Labrador|NS Nova Scotia|NT Northwest Territories|NU Nunavut|ON Ontario|PE Prince Edward Island|QC Quebec|SK Saskatchewan|YT Yukon",
    MY: "Johor|Kedah|Kelantan|Melaka|Negeri Sembilan|Pahang|Penang|Perak|Perlis|Sabah|Sarawak|Selangor|Terengganu|Kuala Lumpur|Labuan|Putrajaya",
    IN: "Andhra Pradesh|Arunachal Pradesh|Assam|Bihar|Chhattisgarh|Goa|Gujarat|Haryana|Himachal Pradesh|Jharkhand|Karnataka|Kerala|Madhya Pradesh|Maharashtra|Manipur|Meghalaya|Mizoram|Nagaland|Odisha|Punjab|Rajasthan|Sikkim|Tamil Nadu|Telangana|Tripura|Uttar Pradesh|Uttarakhand|West Bengal|Delhi|Chandigarh|Jammu and Kashmir|Ladakh|Puducherry",
    GB: "England|Scotland|Wales|Northern Ireland|Greater London|Greater Manchester|West Midlands|West Yorkshire|Merseyside|Kent|Essex|Surrey|Hampshire",
    ID: "DKI Jakarta|Jawa Barat|Jawa Tengah|Jawa Timur|Banten|DI Yogyakarta|Bali|Sumatera Utara|Sumatera Barat|Sumatera Selatan|Riau|Kepulauan Riau|Lampung|Kalimantan Timur|Kalimantan Barat|Sulawesi Selatan|Sulawesi Utara|Nusa Tenggara Barat|Papua",
    TH: "Bangkok|Nonthaburi|Samut Prakan|Pathum Thani|Chiang Mai|Chiang Rai|Phuket|Chonburi|Krabi|Songkhla|Khon Kaen|Nakhon Ratchasima|Udon Thani|Surat Thani|Prachuap Khiri Khan",
    PH: "Metro Manila|Cebu|Davao del Sur|Cavite|Laguna|Rizal|Bulacan|Pampanga|Batangas|Iloilo|Negros Occidental|Benguet|Pangasinan|Misamis Oriental|Zamboanga del Sur",
    VN: "Ho Chi Minh City|Hanoi|Da Nang|Haiphong|Can Tho|Dong Nai|Binh Duong|Khanh Hoa|Quang Ninh|Ba Ria–Vung Tau|Thua Thien Hue|Lam Dong|Bac Ninh",
    JP: "Tokyo|Osaka|Kanagawa|Aichi|Saitama|Chiba|Hyogo|Hokkaido|Fukuoka|Shizuoka|Ibaraki|Hiroshima|Kyoto|Miyagi|Niigata|Nagano|Okinawa|Nara|Kumamoto|Okayama",
    KR: "Seoul|Busan|Incheon|Daegu|Daejeon|Gwangju|Ulsan|Sejong|Gyeonggi-do|Gangwon-do|Chungcheongbuk-do|Chungcheongnam-do|Jeollabuk-do|Jeollanam-do|Gyeongsangbuk-do|Gyeongsangnam-do|Jeju-do",
    CN: "Beijing|Shanghai|Tianjin|Chongqing|Guangdong|Zhejiang|Jiangsu|Shandong|Sichuan|Hubei|Henan|Hunan|Fujian|Anhui|Hebei|Liaoning|Shaanxi|Yunnan|Jiangxi|Guangxi|Heilongjiang|Jilin|Shanxi|Guizhou|Hainan|Inner Mongolia|Xinjiang|Gansu|Ningxia|Qinghai|Tibet",
    TW: "Taipei City|New Taipei City|Taoyuan City|Taichung City|Tainan City|Kaohsiung City|Hsinchu City|Hsinchu County|Keelung City|Chiayi City|Changhua County|Yilan County|Hualien County|Pingtung County",
    NZ: "Auckland|Wellington|Canterbury|Waikato|Bay of Plenty|Otago|Manawatū-Whanganui|Hawke's Bay|Northland|Taranaki|Southland|Nelson|Tasman|Marlborough|Gisborne|West Coast",
    DE: "Baden-Württemberg|Bavaria|Berlin|Brandenburg|Bremen|Hamburg|Hesse|Lower Saxony|Mecklenburg-Vorpommern|North Rhine-Westphalia|Rhineland-Palatinate|Saarland|Saxony|Saxony-Anhalt|Schleswig-Holstein|Thuringia",
    FR: "Île-de-France|Auvergne-Rhône-Alpes|Provence-Alpes-Côte d'Azur|Occitanie|Nouvelle-Aquitaine|Hauts-de-France|Grand Est|Pays de la Loire|Bretagne|Normandie|Bourgogne-Franche-Comté|Centre-Val de Loire|Corse",
    NL: "North Holland|South Holland|Utrecht|North Brabant|Gelderland|Overijssel|Limburg|Groningen|Friesland|Drenthe|Flevoland|Zeeland",
    AE: "Abu Dhabi|Dubai|Sharjah|Ajman|Umm Al Quwain|Ras Al Khaimah|Fujairah",
    MX: "Ciudad de México|Jalisco|Nuevo León|Estado de México|Puebla|Baja California|Quintana Roo|Yucatán|Guanajuato|Querétaro|Veracruz|Chihuahua",
    BR: "SP São Paulo|RJ Rio de Janeiro|MG Minas Gerais|BA Bahia|PR Paraná|RS Rio Grande do Sul|PE Pernambuco|CE Ceará|SC Santa Catarina|GO Goiás|DF Distrito Federal|AM Amazonas|PA Pará",
    IT: "Lazio|Lombardia|Campania|Piemonte|Sicilia|Veneto|Emilia-Romagna|Toscana|Puglia|Liguria|Sardegna|Calabria|Trentino-Alto Adige|Friuli-Venezia Giulia",
    ES: "Madrid|Cataluña|Andalucía|Comunidad Valenciana|País Vasco|Galicia|Castilla y León|Canarias|Islas Baleares|Aragón|Murcia|Navarra",
  };

  const split = s => s.split("|");
  // Entries like "NSW New South Wales" become value=NSW, label=New South Wales; single words stay as-is.
  const coded = s => split(s).map(e => {
    const m = e.match(/^([A-Z]{2,3}) (.+)$/);
    return m ? [m[1], m[2]] : [e, ""];
  });

  const regionsFor = cc => {
    if (cc === "US") {
      const labels = split(REGIONS.US_LABELS);
      return split(REGIONS.US).map((v, i) => [v, labels[i]]);
    }
    return REGIONS[cc] ? coded(REGIONS[cc]) : [];
  };
  const citiesFor = cc => split(CITIES[cc] || GLOBAL_CITIES).map(c => [c, ""]);

  const listFor = (id, build) => {
    let dl = document.getElementById(id);
    if (!dl) {
      dl = document.createElement("datalist");
      dl.id = id;
      for (const [value, label] of build()) {
        const o = document.createElement("option");
        o.value = value;
        if (label) o.textContent = label;
        dl.append(o);
      }
      document.body.append(dl);
    }
    return id;
  };

  const countryOf = input => {
    const scope = input.form || input.closest(".fields") || document;
    const c = scope.querySelector('input[name="country"], input[name="ship_country"]');
    const cc = (c && c.value || "").trim().toUpperCase();
    return /^[A-Z]{2}$/.test(cc) ? cc : "";
  };

  const syncDependents = scope => {
    if (!scope) return;
    scope.querySelectorAll('input[name="city"], input[name="region"]').forEach(el => {
      const cc = countryOf(el);
      if (el.name === "city") {
        el.setAttribute("list", listFor(`as-city-${cc || "ANY"}`, () => citiesFor(cc)));
      } else {
        regionPicker(el, cc);
      }
    });
  };

  // Countries with a known list get a real <select>; others keep the free-text input.
  // Only one of the pair is enabled at a time, so exactly one "region" value is submitted.
  const regionPicker = (input, cc) => {
    const regions = regionsFor(cc);
    let sel = input.parentElement.querySelector("select.region-select");
    if (sel && sel.dataset.cc === cc) return;
    if (!regions.length) {
      // The old country's region doesn't apply to the new one.
      if (sel) { input.value = ""; sel.remove(); }
      input.hidden = false; input.disabled = false;
      return;
    }
    const switching = !!sel;
    const current = (sel ? sel.value : input.value).trim();
    if (!sel) {
      sel = document.createElement("select");
      sel.className = "region-select";
      sel.name = input.name;
      sel.autocomplete = input.getAttribute("autocomplete") || "address-level1";
      sel.addEventListener("change", () => { input.value = sel.value; });
      input.before(sel);
    }
    sel.dataset.cc = cc;
    sel.replaceChildren(new Option(cc === "US" ? "Select a state" : "Select…", ""));
    const lc = current.toLowerCase();
    let matched = !current;
    for (const [value, label] of regions) {
      const o = new Option(label || value, value);
      if (!matched && (value.toLowerCase() === lc || (label && label.toLowerCase() === lc))) { o.selected = true; matched = true; }
      sel.append(o);
    }
    // Keep a saved value that isn't in our list rather than silently dropping it.
    if (!matched && !switching) sel.add(new Option(current, current, true, true), 1);
    input.value = sel.value;
    input.hidden = true; input.disabled = true;
  };

  const COUNTRY_SEL = 'input[name="country"], input[name="ship_country"]';
  const enhance = root => {
    const els = [...root.querySelectorAll(COUNTRY_SEL)];
    if (root.matches && root.matches(COUNTRY_SEL)) els.push(root);
    els.forEach(el => {
      el.setAttribute("list", listFor("as-countries", () => coded(COUNTRIES)));
      syncDependents(el.form || el.closest(".fields"));
    });
  };

  const onCountry = e => {
    const t = e.target;
    if (t.matches && t.matches('input[name="country"], input[name="ship_country"]')) {
      syncDependents(t.form || t.closest(".fields"));
    }
  };
  document.addEventListener("input", onCountry);
  document.addEventListener("change", onCountry);
  // Values set programmatically (e.g. run.js prefilling the country) don't fire input events.
  document.addEventListener("focusin", e => {
    const t = e.target;
    if (t.matches && t.matches('input[name="city"], input[name="region"], select.region-select')) syncDependents(t.form || t.closest(".fields"));
  });

  const start = () => {
    enhance(document);
    new MutationObserver(muts => {
      for (const m of muts) for (const n of m.addedNodes) if (n.nodeType === 1 && n.tagName !== "DATALIST" && n.tagName !== "SELECT") enhance(n);
    }).observe(document.body, { childList: true, subtree: true });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
