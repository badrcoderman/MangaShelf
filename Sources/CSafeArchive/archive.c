#include "CSafeArchive.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

static uint16_t u16(const uint8_t *p) { return (uint16_t)(p[0] | (uint16_t)p[1]<<8); }
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static int span(size_t offset, size_t length, size_t end) {
    return offset <= end && length <= end-offset;
}
static int safe_name(const uint8_t *p, size_t n) {
    if (!n || p[0]=='/') return 0;
    size_t start=0;
    for(size_t i=0; i<=n; i++) {
        if(i<n && (p[i]==0 || p[i]=='\\' || p[i]==':' || p[i]<32)) return 0;
        if(i==n || p[i]=='/') {
            size_t len=i-start;
            if ((len==1 && p[start]=='.') || (len==2 && p[start]=='.' && p[start+1]=='.')) return 0;
            if (!len && i<n) return 0;
            start=i+1;
        }
    }
    return 1;
}

ms_status ms_zip_open(const uint8_t *b, size_t n, ms_zip_limits limits, ms_zip *z) {
    if(!b || !z || n<22) return MS_INVALID;
    size_t floor=n>65557?n-65557:0, e=n-22;
    for(;;) {
        if(u32(b+e)==0x06054b50 && u16(b+e+20)==n-e-22) break;
        if(e==floor) return MS_INVALID;
        e--;
    }
    if(u16(b+e+4) || u16(b+e+6) || u16(b+e+8)!=u16(b+e+10)) return MS_UNSUPPORTED;
    uint32_t count=u16(b+e+10), size=u32(b+e+12), off=u32(b+e+16);
    if(count==65535 || size==UINT32_MAX || off==UINT32_MAX) return MS_UNSUPPORTED;
    if(count>limits.entry_limit) return MS_LIMIT;
    if(!span(off,size,e) || (size_t)off+size!=e) return MS_INVALID;
    memset(z,0,sizeof(*z));
    z->bytes=b; z->size=n; z->central_offset=off; z->central_end=e;
    z->cursor=off; z->count=count; z->limits=limits;
    return MS_OK;
}

ms_status ms_zip_next(ms_zip *z, ms_zip_entry *out) {
    if(!z || !out || !z->bytes) return MS_INVALID;
    if(z->seen==z->count) return z->cursor==z->central_end?MS_DONE:MS_INVALID;
    size_t pos=z->cursor;
    if(!span(pos,46,z->central_end)) return MS_INVALID;
    const uint8_t *c=z->bytes+pos;
    if(u32(c)!=0x02014b50) return MS_INVALID;
    uint16_t flags=u16(c+8), method=u16(c+10), nl=u16(c+28), el=u16(c+30), cl=u16(c+32);
    if(!span(pos+46,(size_t)nl+el+cl,z->central_end)) return MS_INVALID;
    if(flags & (1|0x40|0x2000)) return MS_UNSUPPORTED;
    if(method!=0 && method!=8) return MS_UNSUPPORTED;
    if(u16(c+34)) return MS_UNSUPPORTED;
    uint32_t packed=u32(c+20), expanded=u32(c+24), local=u32(c+42), crc=u32(c+16);
    if(packed==UINT32_MAX || expanded==UINT32_MAX || local==UINT32_MAX) return MS_UNSUPPORTED;
    if(!safe_name(c+46,nl)) return MS_INVALID;
    uint32_t mode=u32(c+38)>>16;
    if((mode & 0170000)==0120000) return MS_UNSUPPORTED;
    if(expanded>z->limits.entry_bytes_limit || z->expanded_total>z->limits.total_bytes_limit ||
       expanded>z->limits.total_bytes_limit-z->expanded_total) return MS_LIMIT;
    if(expanded && (!packed || (uint64_t)expanded>(uint64_t)packed*z->limits.ratio_limit)) return MS_LIMIT;
    if(method==0 && packed!=expanded) return MS_INVALID;
    if(!span(local,30,z->central_offset)) return MS_INVALID;
    const uint8_t *l=z->bytes+local;
    uint16_t lnl=u16(l+26), lel=u16(l+28);
    if(u32(l)!=0x04034b50 || u16(l+6)!=flags || u16(l+8)!=method || lnl!=nl) return MS_INVALID;
    if(!span((size_t)local+30,(size_t)lnl+lel,z->central_offset)) return MS_INVALID;
    if(memcmp(l+30,c+46,nl)) return MS_INVALID;
    if(!(flags & 8) && (u32(l+14)!=crc || u32(l+18)!=packed || u32(l+22)!=expanded)) return MS_INTEGRITY;
    size_t data=(size_t)local+30+lnl+lel;
    if(!span(data,packed,z->central_offset)) return MS_INVALID;
    *out=(ms_zip_entry){c+46,nl,method,flags,packed,expanded,crc,data};
    z->expanded_total+=expanded;
    z->cursor=pos+46+nl+el+cl; z->seen++;
    return MS_OK;
}

static ms_status inflate_exact(const uint8_t *src,size_t length,uint8_t *dst,size_t capacity,
                               size_t *written,int window_bits) {
    if(!src || !dst || !written || !capacity || length>UINT_MAX || capacity>UINT_MAX) return MS_LIMIT;
    z_stream stream; memset(&stream,0,sizeof(stream));
    stream.next_in=(Bytef *)src; stream.avail_in=(uInt)length;
    stream.next_out=dst; stream.avail_out=(uInt)capacity;
    int result=inflateInit2(&stream,window_bits);
    if(result!=Z_OK) return result==Z_MEM_ERROR?MS_MEMORY:MS_INVALID;
    result=inflate(&stream,Z_FINISH);
    *written=(size_t)stream.total_out;
    ms_status status=MS_INVALID;
    if(result==Z_STREAM_END && stream.total_in==length) status=MS_OK;
    else if(result!=Z_STREAM_END && stream.avail_out==0) status=MS_LIMIT;
    else if(result==Z_MEM_ERROR) status=MS_MEMORY;
    inflateEnd(&stream);
    return status;
}

ms_status ms_zip_extract(const ms_zip *z,const ms_zip_entry *e,uint8_t *dst,size_t capacity) {
    if(!z || !e || !dst || !span(e->data_offset,e->compressed_size,z->central_offset)) return MS_INVALID;
    if(e->uncompressed_size>capacity || e->uncompressed_size>z->limits.entry_bytes_limit) return MS_LIMIT;
    const uint8_t *source=z->bytes+e->data_offset;
    if(e->method==0) {
        if(e->compressed_size!=e->uncompressed_size) return MS_INVALID;
        memcpy(dst,source,e->uncompressed_size);
    } else if(e->method==8) {
        size_t written=0;
        ms_status result=inflate_exact(source,e->compressed_size,dst,capacity,&written,-MAX_WBITS);
        if(result!=MS_OK) return result;
        if(written!=e->uncompressed_size) return MS_INTEGRITY;
    } else return MS_UNSUPPORTED;
    return (uint32_t)crc32(0,dst,e->uncompressed_size)==e->crc?MS_OK:MS_INTEGRITY;
}

ms_status ms_gzip_decode(const uint8_t *src,size_t length,uint8_t *dst,size_t capacity,size_t *written) {
    return inflate_exact(src,length,dst,capacity,written,MAX_WBITS+16);
}

static ms_status varint(const uint8_t *b,size_t n,size_t *offset,uint64_t *value) {
    *value=0;
    for(unsigned i=0;i<10;i++) {
        if(*offset>=n) return MS_INVALID;
        uint8_t byte=b[(*offset)++];
        if(i==9 && byte>1) return MS_INVALID;
        *value|=(uint64_t)(byte&127)<<(7*i);
        if(!(byte&128)) return MS_OK;
    }
    return MS_INVALID;
}

ms_status ms_pb_next(const uint8_t *b,size_t n,size_t *offset,ms_pb_field *field) {
    if(!b || !offset || !field || *offset>n) return MS_INVALID;
    if(*offset==n) return MS_DONE;
    size_t cursor=*offset;
    uint64_t tag=0, value=0;
    if(varint(b,n,&cursor,&tag)!=MS_OK || (tag>>3)==0 || (tag>>3)>0x1fffffff) return MS_INVALID;
    memset(field,0,sizeof(*field)); field->number=(uint32_t)(tag>>3); field->wire_type=(uint32_t)(tag&7);
    switch(tag&7) {
        case 0:
            if(varint(b,n,&cursor,&value)!=MS_OK) return MS_INVALID;
            field->integer=value; break;
        case 1: case 5: {
            size_t length=(tag&7)==1?8:4;
            if(!span(cursor,length,n)) return MS_INVALID;
            field->bytes=b+cursor; field->length=length; cursor+=length; break;
        }
        case 2:
            if(varint(b,n,&cursor,&value)!=MS_OK || value>SIZE_MAX || !span(cursor,(size_t)value,n)) return MS_INVALID;
            field->bytes=b+cursor; field->length=(size_t)value; cursor+=(size_t)value; break;
        default: return MS_UNSUPPORTED;
    }
    *offset=cursor;
    return MS_OK;
}

const char *ms_status_message(ms_status s) {
    switch(s) {
        case MS_OK:return "ok"; case MS_INVALID:return "malformed data";
        case MS_LIMIT:return "resource limit exceeded"; case MS_UNSUPPORTED:return "unsupported format";
        case MS_INTEGRITY:return "integrity check failed"; case MS_MEMORY:return "allocation failed";
        case MS_DONE:return "end"; default:return "unknown failure";
    }
}
