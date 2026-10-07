export type FileCategory =
  "document" | "image" | "audio" | "video" | "archive" | "text" | "binary";
export type FileFormat = {
  extension: string;
  mime: string;
  category: FileCategory;
  display: string;
  read: string;
};
const groups: [FileCategory, string, string, Record<string, string>][] = [
  [
    "document",
    "quicklook-or-converted-pdf",
    "extracted-text",
    {
      pdf: "application/pdf",
      docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      doc: "application/msword",
      xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      xls: "application/vnd.ms-excel",
      pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      ppt: "application/vnd.ms-powerpoint",
      rtf: "application/rtf",
      pages: "application/vnd.apple.pages",
      numbers: "application/vnd.apple.numbers",
      key: "application/vnd.apple.keynote",
      odt: "application/vnd.oasis.opendocument.text",
      ods: "application/vnd.oasis.opendocument.spreadsheet",
      odp: "application/vnd.oasis.opendocument.presentation",
    },
  ],
  [
    "image",
    "native-image-or-converted-png",
    "visual-and-metadata",
    {
      jpg: "image/jpeg",
      jpeg: "image/jpeg",
      png: "image/png",
      gif: "image/gif",
      webp: "image/webp",
      heic: "image/heic",
      heif: "image/heif",
      svg: "image/svg+xml",
      tiff: "image/tiff",
      tif: "image/tiff",
      bmp: "image/bmp",
      avif: "image/avif",
    },
  ],
  [
    "audio",
    "native-or-converted-m4a",
    "media-metadata",
    {
      mp3: "audio/mpeg",
      wav: "audio/wav",
      m4a: "audio/mp4",
      aac: "audio/aac",
      flac: "audio/flac",
      ogg: "audio/ogg",
      aiff: "audio/aiff",
    },
  ],
  [
    "video",
    "native-or-converted-mp4",
    "media-metadata",
    {
      mp4: "video/mp4",
      mov: "video/quicktime",
      avi: "video/x-msvideo",
      mkv: "video/x-matroska",
      webm: "video/webm",
      wmv: "video/x-ms-wmv",
      m4v: "video/x-m4v",
    },
  ],
  [
    "archive",
    "entry-list",
    "bounded-entry-list",
    {
      zip: "application/zip",
      rar: "application/vnd.rar",
      "7z": "application/x-7z-compressed",
      tar: "application/x-tar",
      gz: "application/gzip",
      tgz: "application/gzip",
      bz2: "application/x-bzip2",
      xz: "application/x-xz",
    },
  ],
  [
    "text",
    "escaped-source",
    "utf8-text",
    {
      txt: "text/plain",
      csv: "text/csv",
      html: "text/html",
      htm: "text/html",
      json: "application/json",
      xml: "application/xml",
      md: "text/markdown",
      log: "text/plain",
      yaml: "application/yaml",
      yml: "application/yaml",
      ics: "text/calendar",
      vcf: "text/vcard",
    },
  ],
];
export const fileFormats: FileFormat[] = groups.flatMap(
  ([category, display, read, types]) =>
    Object.entries(types).map(([extension, mime]) => ({
      extension,
      mime,
      category,
      display,
      read,
    })),
);
export function fileFormat(name: string): FileFormat {
  const extension = name.includes(".")
    ? name.split(".").pop()!.toLowerCase()
    : "";
  return (
    fileFormats.find((f) => f.extension === extension) ?? {
      extension,
      mime: "application/octet-stream",
      category: "binary",
      display: "download-and-open-with",
      read: "metadata-only",
    }
  );
}
