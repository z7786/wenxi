enum FileKind {
  folder,
  image,
  video,
  audio,
  text,
  pdf,
  archive,
  android,
  other,
}

FileKind fileKind(String name, {bool directory = false}) {
  if (directory) return FileKind.folder;
  final ext = name.split('.').last.toLowerCase();
  if ({'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif'}.contains(ext)) {
    return FileKind.image;
  }
  if ({
    'mp4',
    'mkv',
    'avi',
    'mov',
    'flv',
    'ts',
    'm3u8',
    'm4v',
    'webm',
    'wmv',
  }.contains(ext)) {
    return FileKind.video;
  }
  if ({'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus'}.contains(ext)) {
    return FileKind.audio;
  }
  if (isTextFile(name)) return FileKind.text;
  if ({'zip', 'rar', '7z', 'gz', 'tar', 'iso'}.contains(ext)) {
    return FileKind.archive;
  }
  if (ext == 'apk') return FileKind.android;
  if (ext == 'pdf') return FileKind.pdf;
  return FileKind.other;
}

const _textLanguages = <String, String>{
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'pyw': 'python',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'ps1': 'powershell',
  'psm1': 'powershell',
  'dart': 'dart',
  'java': 'java',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'c': 'c',
  'h': 'c',
  'cpp': 'cpp',
  'cc': 'cpp',
  'hpp': 'cpp',
  'cs': 'csharp',
  'go': 'go',
  'rs': 'rust',
  'php': 'php',
  'rb': 'ruby',
  'lua': 'lua',
  'swift': 'swift',
  'sql': 'sql',
  'json': 'json',
  'jsonc': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'xml': 'xml',
  'html': 'xml',
  'htm': 'xml',
  'svg': 'xml',
  'vue': 'xml',
  'css': 'css',
  'scss': 'scss',
  'ini': 'ini',
  'toml': 'ini',
  'bat': 'dos',
  'cmd': 'dos',
  'md': 'markdown',
  'markdown': 'markdown',
};
const _plainTextExtensions = {
  'txt',
  'text',
  'log',
  'csv',
  'tsv',
  'srt',
  'lrc',
  'conf',
  'config',
  'properties',
  'env',
  'vtt',
  'ass',
  'ssa',
  'gitignore',
  'gitattributes',
  'lock',
};

const _officeExtensions = {
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'odt',
  'ods',
  'odp',
  'rtf',
};

String _textName(String name) {
  var value = name.replaceAll('\\', '/').split('/').last.toLowerCase();
  // These are candidates only. The preview loader rejects real archive bytes.
  if (value.endsWith('.zip')) value = value.substring(0, value.length - 4);
  return value;
}

bool isTextFile(String name) {
  final value = _textName(name), extension = value.split('.').last;
  return {
        'readme',
        'license',
        'licence',
        'makefile',
        'dockerfile',
        '.bashrc',
        '.zshrc',
      }.contains(value) ||
      _plainTextExtensions.contains(extension) ||
      _textLanguages.containsKey(extension);
}

bool isOfficeDocument(String name) {
  final value = name.replaceAll('\\', '/').split('/').last.toLowerCase();
  return _officeExtensions.contains(value.split('.').last);
}

String? textFileLanguage(String name) =>
    _textLanguages[_textName(name).split('.').last];
