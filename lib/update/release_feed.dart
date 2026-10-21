import 'dart:convert';
import 'dart:io';

const releaseFeedUserAgent = 'handy-update-checker';

const _owner = 'iebb';
const _repo = 'Handy';

const releasesPageUrl = 'https://github.com/$_owner/$_repo/releases';

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
  });

  final String name;
  final String url;

  final int size;

  final String? sha256;
}

class ReleaseInfo {
  const ReleaseInfo({required this.version, required this.assets});

  final String version;
  final List<ReleaseAsset> assets;

  ReleaseAsset? assetEndingWith(String suffix) {
    for (final asset in assets) {
      if (asset.name.endsWith(suffix)) return asset;
    }
    return null;
  }
}

Future<ReleaseInfo?> fetchLatestRelease({
  String owner = _owner,
  String repo = _repo,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(
      Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest'),
    );
    request.headers.set(HttpHeaders.userAgentHeader, releaseFeedUserAgent);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    return parseReleaseInfo(body);
  } finally {
    client.close(force: true);
  }
}

ReleaseInfo? parseReleaseInfo(String body) {
  final json = jsonDecode(body);
  if (json is! Map<String, dynamic>) return null;
  final tag = json['tag_name'] as String?;
  if (tag == null) return null;
  final assets = ((json['assets'] as List?) ?? const [])
      .whereType<Map>()
      .map(
        (asset) => ReleaseAsset(
          name: (asset['name'] as String?) ?? '',
          url: (asset['browser_download_url'] as String?) ?? '',
          size: (asset['size'] as num?)?.toInt() ?? 0,
          sha256: _hexDigest(asset['digest'] as String?),
        ),
      )
      .where((asset) => asset.url.isNotEmpty)
      .toList();
  return ReleaseInfo(
    version: tag.replaceFirst(RegExp(r'^v'), ''),
    assets: assets,
  );
}

String? _hexDigest(String? digest) {
  const prefix = 'sha256:';
  if (digest == null || !digest.startsWith(prefix)) return null;
  final hex = digest.substring(prefix.length).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
  return hex;
}

int compareReleaseVersions(String a, String b) {
  final pa = _triple(a);
  final pb = _triple(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] - pb[i];
  }
  return 0;
}

List<int> _triple(String version) {
  final core = version.split(RegExp(r'[+\-]')).first;
  final numbers = core
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList();
  while (numbers.length < 3) {
    numbers.add(0);
  }
  return numbers.sublist(0, 3);
}
