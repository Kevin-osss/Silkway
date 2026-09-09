#!/usr/bin/env python3
"""Read a local extracted Sketch kit. Python 3.9+, standard library only."""
import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parents[1]
SOURCES={'components':'catalog/components.jsonl','page-elements':'catalog/page-elements.jsonl',
         'colors':'tokens/colors.json','text-styles':'tokens/text-styles.json',
         'layer-styles':'tokens/layer-styles.json'}

def emit(obj):
    print(json.dumps(obj,ensure_ascii=False,indent=2))

@lru_cache(maxsize=None)
def read(path):
    p=ROOT/path
    if p.suffix=='.jsonl':return [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
    return json.loads(p.read_text())

@lru_cache(maxsize=3)
def member(name):
    with zipfile.ZipFile(ROOT/'evidence/source-json.zip') as z:return json.loads(z.read(name))

def pointer(obj,path):
    for part in path.split('/')[1:]:
        key=part.replace('~1','/').replace('~0','~')
        obj=obj[int(key)] if isinstance(obj,list) else obj[key]
    return obj

def raw(record):return pointer(member(record['source_member']),record['json_pointer'])

def brief(record):
    return {k:v for k,v in record.items() if k not in ('raw','foreign_wrapper_raw','references','layer_path')}

def locate(identity):
    matches=[]
    for scope,filename in SOURCES.items():
        for record in read(filename):
            if identity in (record.get('symbol_id'),record.get('layer_id'),record.get('id')):
                return scope,record
            if record['name']==identity:matches.append((scope,record))
    if len(matches)==1:return matches[0]
    if len(matches)>1:
        emit({'error':'Ambiguous name; use an ID.','matches':[brief(r) for _,r in matches]})
        raise SystemExit(2)
    raise ValueError('No exact ID or name found. Run search first.')

def summarize(node,depth):
    wanted=('_class','do_objectID','name','symbolID','frame','isVisible','rotation','isFlippedHorizontal',
            'isFlippedVertical','isLocked','sharedStyleID','style','attributedString','image',
            'overrideValues','overrideProperties','allowsOverrides','groupLayout','groupBehavior',
            'leftPadding','rightPadding','topPadding','bottomPadding','paddingSelection','flexItem',
            'horizontalSizing','verticalSizing','horizontalPins','verticalPins','resizingConstraint',
            'resizingType','resizesContent','clippingBehavior','clippingMaskMode','hasClippingMask',
            'includeBackgroundColorInExport','includeBackgroundColorInInstance','backgroundColor',
            'preferredThumbnailBackground','preventInserting','preventSwapping','preventUseAsOverride')
    result={k:node[k] for k in wanted if k in node}
    omitted=[k for k in node if k not in wanted and k!='layers']
    if omitted:result['_other_source_keys_available_with_raw']=omitted
    children=node.get('layers',[])
    if children:
        result['_child_layer_count']=len(children)
        if depth>0:result['layers']=[summarize(n,depth-1) for n in children]
        else:result['_child_layers_omitted']=True
    return result

def issues(record):
    candidates=read('evidence/reference-audit.json')['unresolved_references']
    result=[]
    for r in candidates:
        if record.get('symbol_id') and r.get('owner_symbol_id')==record['symbol_id']:
            result.append(r)
        elif r['source_member']==record['source_member'] and (
            r['json_pointer']==record['json_pointer'] or
            r['json_pointer'].startswith(record['json_pointer']+'/')):
            result.append(r)
    return result

def lookup_deps(record):
    refs=record.get('references',{})
    symbols={r['symbol_id']:r for r in read(SOURCES['components'])}
    colors={r['id']:r for r in read(SOURCES['colors'])}
    styles={r['id']:r for r in read(SOURCES['text-styles'])+read(SOURCES['layer-styles'])}
    output={}
    for kind,ids in refs.items():
        defs=symbols if kind.startswith('symbol_') else colors if kind=='swatches' else styles
        output[kind]=[{'id':i,'resolved':i in defs,'name':defs[i]['name'] if i in defs else None} for i in ids]
    return output

def search(args):
    data=read(SOURCES[args.scope])
    def match(r):
        if args.category and args.category.casefold()!=r.get('category','').casefold():return False
        text=' '.join(str(r.get(k,'')) for k in ('name','category','layer_id','symbol_id','id')).casefold()
        return all(t.casefold() in text for t in args.terms)
    hits=sorted((r for r in data if match(r)),key=lambda r:(r['name'].casefold(),r.get('symbol_id',r.get('id',''))))
    emit({'scope':args.scope,'total_matches':len(hits),'returned':min(len(hits),args.limit),
          'results':[brief(r) for r in hits[:args.limit]]})

def show(args):
    scope,record=locate(args.identity)
    obj=raw(record)
    visuals=ROOT/'visuals/manifest.json'
    previews=[]
    if visuals.exists():
        previews=[v for v in read('visuals/manifest.json').get('items',[])
                  if v.get('source_layer_id')==record.get('layer_id') or
                  (record.get('symbol_id') and v.get('source_symbol_id')==record['symbol_id'])]
    emit({'scope':scope,'record':brief(record),
          'source':{'archive':'evidence/source-json.zip','member':record['source_member'],
                    'json_pointer':record['json_pointer'],'source_sketch_sha256':read('manifest.json')['source']['sha256']},
          'interpretation':'Sketch asset data, not automatically native SDK constants. Name segments are preserved, not inferred API values.',
          'representation':'full raw source object' if args.raw or scope not in ('components','page-elements') else f'bounded layer summary, depth={args.depth}; use --raw for all fields and descendants',
          'data':obj if args.raw or scope not in ('components','page-elements') else summarize(obj,args.depth),
          'dependencies':lookup_deps(record),'unresolved_source_references':issues(record),'previews':previews})

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def verify(args):
    manifest=read('manifest.json');errors=[]
    if sha(ROOT/'evidence/source-json.zip')!=manifest['evidence_archive_sha256']:errors.append('Evidence archive hash mismatch')
    with zipfile.ZipFile(ROOT/'evidence/source-json.zip') as z:
        for item in read('evidence/json-member-hashes.json'):
            if hashlib.sha256(z.read(item['member'])).hexdigest()!=item['sha256']:errors.append('Member hash mismatch: '+item['member'])
    source_checked=False
    if args.source:
        source_checked=True
        if sha(args.source)!=manifest['source']['sha256']:errors.append('Original .sketch hash mismatch')
    # Check every index pointer and field against independent lossless source data.
    checked=0
    for scope,filename in SOURCES.items():
        for record in read(filename):
            obj=raw(record);checked+=1
            expected_id=record.get('layer_id',record.get('id'))
            if obj.get('do_objectID')!=expected_id or obj.get('name')!=record['name']:
                errors.append('ID/name mismatch: '+str(expected_id))
            if scope in ('components','page-elements'):
                if obj.get('frame')!=record.get('frame'):errors.append('Frame mismatch: '+str(expected_id))
                if scope=='components' and obj.get('symbolID')!=record['symbol_id']:errors.append('Symbol ID mismatch: '+str(expected_id))
            elif obj!=record['raw']:errors.append('Style/color raw mismatch: '+str(expected_id))
    original_ids=set();original_classes=Counter()
    def walk(node):
        original_classes[node.get('_class')]+=1
        if node.get('_class')=='symbolMaster':original_ids.add((node['do_objectID'],node['symbolID']))
        for child in node.get('layers',[]):walk(child)
    for page in read('catalog/pages.json'):walk(member(page['source_member']))
    indexed_ids={(r['layer_id'],r['symbol_id']) for r in read(SOURCES['components'])}
    if original_ids!=indexed_ids:errors.append('Component index is incomplete or contains extra definitions')
    if dict(original_classes)!=manifest['all_layer_classes']:errors.append('Layer counts mismatch')
    result={'status':'passed' if not errors else 'failed','errors':errors,'checked_records':checked,
            'counts':manifest['counts'],'source_file_hash_checked':source_checked,
            'source_reference_gaps_preserved':read('evidence/reference-audit.json')['unresolved_occurrences'],
            'scope':'Verifies extraction consistency and hashes; not macOS runtime appearance or SDK conformance.'}
    emit(result)
    if errors:raise SystemExit(1)

def render(args):
    scope,record=locate(args.identity)
    if scope not in ('components','page-elements'):raise ValueError('Only a component or page element has a renderable layer ID.')
    source=Path(args.source or read('manifest.json')['source']['original_path']).expanduser().resolve()
    if not source.is_file():raise ValueError('Original .sketch file required; pass --source /path/to/file.sketch')
    if sha(source)!=read('manifest.json')['source']['sha256']:raise ValueError('Source file does not match this kit snapshot. Regenerate the index for another version.')
    cli=Path(args.sketchtool).expanduser().resolve()
    if not cli.is_file():raise ValueError('Sketch CLI is not available; no image has been generated.')
    destination=Path(args.output).expanduser().resolve();destination.mkdir(parents=True,exist_ok=True)
    files=[]
    # A fresh staging directory prevents an older PNG from masking a failed export.
    with tempfile.TemporaryDirectory(prefix='.sketch-export-',dir=destination) as stage:
        command=[str(cli),'export','layers',str(source),'--item='+record['layer_id'],
                 '--output='+stage,'--formats=png','--scales=2','--use-id-for-name=YES']
        result=subprocess.run(command,capture_output=True,text=True)
        generated=list(Path(stage).glob(record['layer_id']+'*.png'))
        if result.returncode==0:
            for png in generated:
                with png.open('rb') as f:header=f.read(8)
                if header!=b'\x89PNG\r\n\x1a\n':raise ValueError('Renderer output is not a PNG: '+png.name)
                dest=destination/png.name
                shutil.copy2(png,dest);files.append(dest)
    emit({'exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
          'layer_id':record['layer_id'],'files':[str(p) for p in files],
          'note':'Native Sketch export; inspect the PNG before accepting. Not a macOS app runtime screenshot.'})
    if result.returncode or not files:raise SystemExit(1)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('search');p.add_argument('terms',nargs='*');p.add_argument('--scope',choices=SOURCES,default='components');p.add_argument('--category');p.add_argument('--limit',type=int,default=10);p.set_defaults(func=search)
    p=sub.add_parser('show');p.add_argument('identity');p.add_argument('--raw',action='store_true');p.add_argument('--depth',type=int,choices=range(0,9),default=1);p.set_defaults(func=show)
    p=sub.add_parser('pages');p.set_defaults(func=lambda a:emit(read('catalog/pages.json')))
    p=sub.add_parser('notes');p.add_argument('terms',nargs='*');p.add_argument('--limit',type=int,default=10);p.set_defaults(func=lambda a:emit([n for n in read('notes/page-text.jsonl') if all(t.casefold() in (n['category']+' '+n['text']).casefold() for t in a.terms)][:a.limit]))
    p=sub.add_parser('audit');p.set_defaults(func=lambda a:emit(read('evidence/reference-audit.json')))
    p=sub.add_parser('verify');p.add_argument('--source');p.set_defaults(func=verify)
    p=sub.add_parser('render');p.add_argument('identity');p.add_argument('--source');p.add_argument('--sketchtool',default='/Applications/Sketch.app/Contents/MacOS/sketchtool');p.add_argument('--output',required=True);p.set_defaults(func=render)
    args=parser.parse_args()
    if hasattr(args,'limit') and args.limit<1:parser.error('--limit must be positive')
    try:args.func(args)
    except (ValueError,OSError,KeyError,zipfile.BadZipFile) as e:
        emit({'error':str(e)});raise SystemExit(2)

if __name__=='__main__':main()
