// MCP-Store: empfohlene Server bekannter Anbieter und Suche im offiziellen
// MCP Registry (registry.modelcontextprotocol.io). Junels nutzt nur Remote-Server
// (HTTP); lokale Pakete (npx/uvx/Docker) werden ausgeblendet.

import 'dart:convert';

import 'network_tools.dart' show httpGetText;

enum McpAuth { none, oauth, token }

class McpHeaderSpec {
  const McpHeaderSpec(this.name, this.description, {this.secret = true, this.required = true});
  final String name;
  final String description;
  final bool secret;
  final bool required;
}

class McpStoreEntry {
  const McpStoreEntry({
    required this.id,
    required this.title,
    required this.vendor,
    required this.description,
    required this.url,
    this.auth = McpAuth.oauth,
    this.category = '',
    this.website = '',
    this.official = true,
    this.headers = const [],
  });
  final String id;
  final String title;
  final String vendor;
  final String description;
  final String url;
  final McpAuth auth;
  final String category;
  final String website;
  final bool official;
  final List<McpHeaderSpec> headers;

  String get authLabel => switch (auth) {
        McpAuth.none => 'ohne Anmeldung',
        McpAuth.oauth => 'Anmeldung im Browser',
        McpAuth.token => 'Token nötig',
      };
}

/// Empfohlene Server direkt von den Anbietern (Stand Ende 2026).
const featuredMcpServers = <McpStoreEntry>[
  McpStoreEntry(id: 'ms-learn', title: 'Microsoft Learn', vendor: 'Microsoft', category: 'Wissen',
      description: 'Offizielle Microsoft-Dokumentation durchsuchen (Azure, .NET, Microsoft 365 …).',
      url: 'https://learn.microsoft.com/api/mcp', auth: McpAuth.none, website: 'https://learn.microsoft.com'),
  McpStoreEntry(id: 'cloudflare-docs', title: 'Cloudflare Docs', vendor: 'Cloudflare', category: 'Wissen',
      description: 'Cloudflare-Dokumentation durchsuchen.', url: 'https://docs.mcp.cloudflare.com/mcp', auth: McpAuth.none,
      website: 'https://developers.cloudflare.com'),
  McpStoreEntry(id: 'deepwiki', title: 'DeepWiki', vendor: 'Cognition', category: 'Wissen',
      description: 'Fragen zu jedem öffentlichen GitHub-Projekt beantworten (Doku aus dem Code).',
      url: 'https://mcp.deepwiki.com/mcp', auth: McpAuth.none, website: 'https://deepwiki.com'),
  McpStoreEntry(id: 'context7', title: 'Context7', vendor: 'Upstash', category: 'Wissen',
      description: 'Aktuelle Doku und Code-Beispiele zu Programmier-Bibliotheken.',
      url: 'https://mcp.context7.com/mcp', auth: McpAuth.none, website: 'https://context7.com'),
  McpStoreEntry(id: 'huggingface', title: 'Hugging Face', vendor: 'Hugging Face', category: 'KI',
      description: 'Modelle, Datensätze, Spaces und Papers auf Hugging Face suchen.',
      url: 'https://huggingface.co/mcp', auth: McpAuth.none, website: 'https://huggingface.co'),
  McpStoreEntry(id: 'github', title: 'GitHub', vendor: 'GitHub', category: 'Entwicklung',
      description: 'Repositories, Issues, Pull Requests und Code durchsuchen und bearbeiten.',
      url: 'https://api.githubcopilot.com/mcp/', auth: McpAuth.token, website: 'https://github.com',
      headers: [McpHeaderSpec('Authorization', 'Bearer <persönlicher GitHub-Token>')]),
  McpStoreEntry(id: 'notion', title: 'Notion', vendor: 'Notion', category: 'Produktivität',
      description: 'Seiten und Datenbanken in Notion suchen, lesen und anlegen.', url: 'https://mcp.notion.com/mcp',
      website: 'https://notion.so'),
  McpStoreEntry(id: 'atlassian', title: 'Atlassian (Jira & Confluence)', vendor: 'Atlassian', category: 'Produktivität',
      description: 'Jira-Tickets und Confluence-Seiten suchen, lesen und bearbeiten.',
      url: 'https://mcp.atlassian.com/v1/mcp', website: 'https://atlassian.com'),
  McpStoreEntry(id: 'linear', title: 'Linear', vendor: 'Linear', category: 'Produktivität',
      description: 'Issues und Projekte in Linear verwalten.', url: 'https://mcp.linear.app/mcp', website: 'https://linear.app'),
  McpStoreEntry(id: 'asana', title: 'Asana', vendor: 'Asana', category: 'Produktivität',
      description: 'Aufgaben und Projekte in Asana.', url: 'https://mcp.asana.com/sse', website: 'https://asana.com'),
  McpStoreEntry(id: 'canva', title: 'Canva', vendor: 'Canva', category: 'Design',
      description: 'Designs in Canva suchen und erstellen.', url: 'https://mcp.canva.com/mcp', website: 'https://canva.com'),
  McpStoreEntry(id: 'sentry', title: 'Sentry', vendor: 'Sentry', category: 'Entwicklung',
      description: 'Fehler und Abstürze aus Sentry analysieren.', url: 'https://mcp.sentry.dev/mcp', website: 'https://sentry.io'),
  McpStoreEntry(id: 'vercel', title: 'Vercel', vendor: 'Vercel', category: 'Entwicklung',
      description: 'Projekte, Deployments und Logs auf Vercel.', url: 'https://mcp.vercel.com', website: 'https://vercel.com'),
  McpStoreEntry(id: 'neon', title: 'Neon', vendor: 'Neon', category: 'Entwicklung',
      description: 'Postgres-Datenbanken bei Neon verwalten und abfragen.', url: 'https://mcp.neon.tech/mcp',
      website: 'https://neon.tech'),
  McpStoreEntry(id: 'stripe', title: 'Stripe', vendor: 'Stripe', category: 'Finanzen',
      description: 'Zahlungen, Kunden und Rechnungen in Stripe.', url: 'https://mcp.stripe.com', website: 'https://stripe.com'),
  McpStoreEntry(id: 'paypal', title: 'PayPal', vendor: 'PayPal', category: 'Finanzen',
      description: 'Rechnungen, Bestellungen und Transaktionen bei PayPal.', url: 'https://mcp.paypal.com/mcp',
      website: 'https://paypal.com'),
  McpStoreEntry(id: 'intercom', title: 'Intercom', vendor: 'Intercom', category: 'Kundenservice',
      description: 'Gespräche und Kontakte in Intercom durchsuchen.', url: 'https://mcp.intercom.com/mcp',
      website: 'https://intercom.com'),
  McpStoreEntry(id: 'webflow', title: 'Webflow', vendor: 'Webflow', category: 'Web',
      description: 'Webflow-Seiten und CMS-Inhalte verwalten.', url: 'https://mcp.webflow.com/sse', website: 'https://webflow.com'),
];

/// Domain-Teil eines Registry-Namens ("com.notion/mcp" → "notion.com", "io.github.user/x" → "github.com/user").
String registryPublisher(String name) {
  final ns = name.split('/').first.split('.');
  if (ns.length >= 2 && ns[0] == 'io' && ns[1] == 'github') return 'github.com/${ns.length > 2 ? ns[2] : ''}';
  return ns.reversed.join('.');
}

/// Gehört die Server-Adresse zur Domain des Herausgebers? Dann gilt er als „vom Anbieter“.
bool registryOfficial(String name, String url) {
  final pub = registryPublisher(name);
  if (pub.startsWith('github.com/')) return false;
  final host = Uri.tryParse(url)?.host ?? '';
  final parts = pub.split('.');
  final base = parts.length >= 2 ? parts.sublist(parts.length - 2).join('.') : pub;
  return host == base || host.endsWith('.$base');
}

/// Einträge aus einer Registry-Antwort (v0 / v0.1) lesen; nur Remote-Server.
List<McpStoreEntry> parseRegistry(String body) {
  final j = jsonDecode(body);
  final list = (j is Map ? (j['servers'] as List? ?? const []) : (j is List ? j : const [])).cast<Object?>();
  final out = <McpStoreEntry>[];
  final seen = <String>{};
  for (final raw in list) {
    if (raw is! Map) continue;
    final s = (raw['server'] is Map ? raw['server'] as Map : raw).cast<String, dynamic>();
    final name = s['name'] as String? ?? '';
    final remotes = (s['remotes'] as List? ?? const []).whereType<Map>().toList();
    if (name.isEmpty || remotes.isEmpty || !seen.add(name)) continue;
    final meta = raw['_meta'] is Map ? raw['_meta'] as Map : const {};
    final official = meta['io.modelcontextprotocol.registry/official'];
    if (official is Map && official['status'] != null && official['status'] != 'active') continue;
    final r = remotes.firstWhere((x) => x['type'] == 'streamable-http', orElse: () => remotes.first);
    final url = r['url'] as String? ?? '';
    if (url.contains('{')) continue; // Vorlagen mit Variablen (z. B. Mandant) überspringen
    final headers = [
      for (final h in (r['headers'] as List? ?? const []).whereType<Map>())
        McpHeaderSpec(h['name'] as String? ?? '', h['description'] as String? ?? '',
            secret: h['isSecret'] == true, required: h['isRequired'] == true),
    ];
    out.add(McpStoreEntry(
      id: name,
      title: (s['title'] as String?)?.trim().isNotEmpty == true ? s['title'] as String : name.split('/').last,
      vendor: registryPublisher(name),
      description: s['description'] as String? ?? '',
      url: url,
      auth: headers.any((h) => h.required) ? McpAuth.token : McpAuth.oauth,
      website: s['websiteUrl'] as String? ?? ((s['repository'] as Map?)?['url'] as String? ?? ''),
      official: registryOfficial(name, url),
      headers: headers,
    ));
  }
  out.sort((a, b) => (b.official ? 1 : 0) - (a.official ? 1 : 0));
  return out;
}

/// Im offiziellen MCP Registry suchen.
Future<List<McpStoreEntry>> searchMcpRegistry(String query,
    {Future<String> Function(Uri) fetcher = httpGetText, int limit = 50}) async {
  final u = Uri.https('registry.modelcontextprotocol.io', '/v0.1/servers',
      {'search': query.trim(), 'version': 'latest', 'limit': '$limit'});
  return parseRegistry(await fetcher(u));
}
