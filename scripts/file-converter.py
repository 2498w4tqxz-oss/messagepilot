#!/usr/bin/env python3
"""Bounded conversion inside the gateway's macOS sandbox. Never execute archive entries."""
import sys, os, json, pathlib, subprocess, zipfile, gzip, html, re, resource, xml.etree.ElementTree as ET
job = pathlib.Path(sys.argv[1])
ext = sys.argv[2]
src = job / ('input.' + ext)
result = {'status': 'unavailable', 'text': '', 'metadata': {}, 'preview': None, 'warnings': []}
resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024 * 1024, 256 * 1024 * 1024))
resource.setrlimit(resource.RLIMIT_CPU, (80, 80))
LIMIT = 1024 * 1024
TOOLS = json.loads((job / 'tools.json').read_text())

def run(tool, args, timeout=60):
    binary = TOOLS.get(tool)
    if not binary:
        raise ValueError('Missing converter: ' + tool)
    with (job / 'tool.stdout').open('wb') as out, (job / 'tool.stderr').open('wb') as err:
        subprocess.run([binary, *map(str, args)], cwd=job, stdout=out, stderr=err, timeout=timeout, check=True)
    with (job / 'tool.stdout').open('rb') as out:
        return out.read(LIMIT + 1)

def text(v):
    result['text'] = v[:LIMIT]
    if len(v) > LIMIT:
        result['warnings'].append('Text truncated at configured read limit')

def preview(p):
    if p.exists() and p.stat().st_size > 0:
        result['preview'] = p.name

def zip_safe():
    z = zipfile.ZipFile(src)
    infos = z.infolist()
    if len(infos) > 10000 or sum((i.file_size for i in infos)) > 100 * 1024 * 1024:
        raise ValueError('Archive exceeds expanded-size/member limit')
    if any((i.file_size > 32 * 1024 * 1024 or i.file_size > max(1, i.compress_size) * 300 for i in infos)):
        raise ValueError('Archive compression/member limit exceeded')
    return z

def xml_text(z, name):
    raw = z.read(name)
    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():
        raise ValueError('XML entities are not allowed')
    root = ET.fromstring(raw)
    return '\n'.join((v.text for v in root.iter() if v.text and v.tag.split('}')[-1] in ['t', 'v', 'p', 'h']))

def pdf_text(p):
    out = job / 'extracted.txt'
    run('pdftotext', ['-enc', 'UTF-8', p, out])
    text(out.read_text(errors='replace'))

def office():
    profile = job / 'office-profile'
    profile.mkdir(exist_ok=True)
    (profile / 'user').mkdir(exist_ok=True)
    (profile / 'user' / 'registrymodifications.xcu').write_text('<?xml version="1.0"?><oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item></oor:items>')
    run('soffice', ['-env:OSL_SOCKET_PATH=' + os.environ.get('OSL_SOCKET_PATH', str(job)), '-env:UserInstallation=' + profile.as_uri(), '--headless', '--nologo', '--nodefault', '--norestore', '--convert-to', 'pdf', '--outdir', job, src])
    p = job / 'input.pdf'
    if not p.exists():
        raise ValueError('Office converter produced no PDF')
    preview(p)
    if not result['text']:
        try:
            pdf_text(p)
        except Exception:
            result['warnings'].append('PDF preview produced; text extraction unavailable')
try:
    if ext in ['txt', 'csv', 'html', 'htm', 'json', 'xml', 'md', 'log', 'yaml', 'yml', 'ics', 'vcf']:
        raw = src.open('rb').read(LIMIT + 1)
        value = raw.decode('utf-8-sig', errors='replace')
        text(value)
        if ext == 'json':
            try:
                text(json.dumps(json.loads(value), indent=2, ensure_ascii=False))
            except Exception:
                result['warnings'].append('Invalid or truncated JSON; source shown')
        p = job / 'preview.txt'
        p.write_text(result['text'])
        preview(p)
    elif ext == 'pdf':
        try:
            pdf_text(src)
        except Exception:
            result['warnings'].append('Text extraction failed; scanned/encrypted PDF may need OCR/password')
        preview(src)
    elif ext in ['docx', 'xlsx', 'pptx', 'pages', 'numbers', 'key', 'odt', 'ods', 'odp']:
        with zip_safe() as z:
            names = z.namelist()
            if ext == 'docx':
                text(xml_text(z, 'word/document.xml'))
            elif ext == 'pptx':
                text('\n\n'.join((xml_text(z, n) for n in sorted(names, key=lambda n: int(re.search('slide(\\d+)', n).group(1)) if re.search('slide(\\d+)', n) else 0) if re.fullmatch('ppt/slides/slide\\d+\\.xml', n))))
            elif ext == 'xlsx':
                strings = []
                if 'xl/sharedStrings.xml' in names:
                    raw = z.read('xl/sharedStrings.xml')
                    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():
                        raise ValueError('XML entities are not allowed')
                    strings = [''.join(x.itertext()) for x in ET.fromstring(raw)]
                lines = []
                total = 0
                for name in sorted((n for n in names if re.fullmatch('xl/worksheets/sheet\\d+\\.xml', n))):
                    raw = z.read(name)
                    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():
                        raise ValueError('XML entities are not allowed')
                    lines.append(name)
                    for row in ET.fromstring(raw).iter('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}row'):
                        cells = []
                        for c in row:
                            v = ''.join((v.text or '' for v in c.iter() if v.tag.split('}')[-1] in ['v', 't']))
                            if c.get('t') == 's' and v.isdigit() and (int(v) < len(strings)):
                                v = strings[int(v)]
                            cells.append(c.get('r', '') + '=' + v)
                        line = '\t'.join(cells)
                        lines.append(line)
                        total += len(line)
                        if total > LIMIT:
                            break
                    if total > LIMIT:
                        break
                text('\n'.join(lines))
            elif 'content.xml' in names:
                text(xml_text(z, 'content.xml'))
            else:
                for candidate in ['QuickLook/Preview.pdf', 'preview.pdf', 'QuickLook/Thumbnail.jpg', 'preview.jpg']:
                    if candidate in names:
                        p = job / ('preview' + pathlib.Path(candidate).suffix)
                        p.write_bytes(z.read(candidate))
                        preview(p)
                        break
                result['metadata']['packageEntries'] = len(names)
        try:
            office()
        except Exception:
            result['warnings'].append('Full document PDF conversion unavailable; native Quick Look or embedded preview may still open the original')
            if result['text'] and (not result['preview']):
                p = job / 'preview.txt'
                p.write_text(result['text'])
                preview(p)
    elif ext in ['doc', 'xls', 'ppt', 'rtf']:
        try:
            office()
        except Exception:
            if ext not in ['doc', 'rtf']:
                raise
            text(run('textutil', ['-convert', 'txt', '-stdout', src]).decode('utf-8', errors='replace'))
            p = job / 'preview.txt'
            p.write_text(result['text'])
            preview(p)
            result['warnings'].append('Text-only preview; native Quick Look opens original formatting')
    elif ext in ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'svg', 'tiff', 'tif', 'bmp', 'avif']:
        p = job / 'preview.png'
        try:
            from PIL import Image
        except ImportError:
            Image = None
        try:
            if Image is None:
                raise ValueError('Pillow is not installed')
            Image.MAX_IMAGE_PIXELS = 40000000
            with Image.open(src) as im:
                if im.width * im.height > 40000000:
                    raise Image.DecompressionBombError('Image too large')
                result['metadata'] = {'width': im.width, 'height': im.height, 'frames': getattr(im, 'n_frames', 1)}
                im.thumbnail((2000, 2000))
                im.convert('RGBA').save(p)
        except Exception as exc:
            if Image is not None and isinstance(exc, (Image.DecompressionBombError, Image.DecompressionBombWarning)):
                raise ValueError('Image dimensions exceed limit')
            if ext == 'svg':
                run('magick', ['-limit', 'memory', '128MiB', '-limit', 'map', '256MiB', src, '-resize', '2000x2000>', p])
            else:
                result['metadata'] = json.loads(run('image', ['%s' % src, '%s' % p]))
        preview(p)
        if ext == 'gif':
            result['warnings'].append('Preview is the first frame; original retains animation')
    elif ext in ['mp4', 'mov', 'avi', 'mkv', 'webm', 'wmv', 'm4v', 'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'aiff']:
        probe = json.loads(run('ffprobe', ['-v', 'error', '-protocol_whitelist', 'file,pipe', '-show_entries', 'format=duration:stream=codec_name,codec_type,width,height,sample_rate,channels', '-of', 'json', src]))
        result['metadata'] = probe
        video = any((s.get('codec_type') == 'video' for s in probe.get('streams', [])))
        p = job / ('preview.mp4' if video else 'preview.m4a')
        args = ['-nostdin', '-v', 'error', '-protocol_whitelist', 'file,pipe', '-i', src, '-t', '600', '-map_metadata', '-1']
        if video:
            args += ['-map', '0:v:0', '-map', '0:a:0?', '-vf', 'scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac']
        else:
            args += ['-vn', '-c:a', 'aac', '-b:a', '160k']
        run('ffmpeg', args + ['-movflags', '+faststart', '-y', p], 75)
        preview(p)
        if float(probe.get('format', {}).get('duration', 0)) > 600:
            result['warnings'].append('Preview limited to first 600 seconds; original download is complete')
        result['warnings'].append('Read result is media metadata, not transcription')
    elif ext in ['zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz']:
        if ext == 'zip':
            with zip_safe() as z:
                entries = [{'name': i.filename, 'size': i.file_size, 'directory': i.is_dir()} for i in z.infolist()[:2000]]
                result['metadata'] = {'entries': entries, 'entryCount': len(z.infolist()), 'truncated': len(z.infolist()) > 2000}
                text('\n'.join((f"{x['size']}\t{x['name']}" for x in entries)))
        elif ext == 'gz':
            with gzip.open(src, 'rb') as f:
                raw = f.read(LIMIT + 1)
            text(raw.decode('utf-8', errors='replace'))
            result['warnings'].append('Gzip read is a bounded decompressed prefix; nested archives are not expanded')
        else:
            text(run('tar', ['-tf', src]).decode('utf-8', errors='replace'))
        p = job / 'preview.txt'
        p.write_text(result['text'])
        preview(p)
        result['warnings'].append('Archives are listed only; entries are never executed or automatically extracted')
    else:
        result['warnings'].append('Unknown format: original storage/download/open-with remain available')
    result['status'] = 'ready' if result['preview'] or result['text'] or result['metadata'] else 'unavailable'
except Exception as exc:
    result['warnings'].append(type(exc).__name__ + ': conversion unavailable or input invalid')
    if result['preview'] or result['text']:
        result['status'] = 'partial'
(job / 'result.json').write_text(json.dumps(result, ensure_ascii=False))
