// genex/raster CPU worker v1. Only coverage comes from Cairo. All color
// arithmetic is project-owned premultiplied linear-sRGB float32.
#include <cairo.h>
#include <png.h>
#include <zlib.h>
#include <algorithm>
#include <array>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace raster {
constexpr size_t max_pixels = 4194304, max_work = 200000000;
struct Reader {
  std::ifstream in{"request.txt"};
  size_t tokens=0;
  double number(double lo=-1000000, double hi=1000000) {
    double v;
    if (++tokens>2000000 || !(in>>v) || !std::isfinite(v) || v<lo || v>hi)
      throw std::runtime_error("invalid or excessive numeric request");
    return v;
  }
  int integer(int lo, int hi) {
    double v=number(lo,hi);
    if (v!=std::floor(v)) throw std::runtime_error("expected integer");
    return int(v);
  }
  double grid(double lo=-1000000, double hi=1000000, double scale=1024) {
    double v=number(lo,hi);
    if (v*scale!=std::nearbyint(v*scale)) throw std::runtime_error("unnormalized number");
    return v;
  }
  float unit() { return float(grid(0,1,65536)); }
};
struct Pixel { float r=0,g=0,b=0,a=0; };
using Surface=std::vector<Pixel>;
using Mask=std::vector<float>;
float linear(float c) { return c<=0.04045f?c/12.92f:std::pow((c+0.055f)/1.055f,2.4f); }
float srgb(float c) { return c<=0.0031308f?12.92f*c:1.055f*std::pow(c,1.0f/2.4f)-0.055f; }
Pixel color(Reader& r) {
  float red=r.integer(0,255)/255.f, green=r.integer(0,255)/255.f;
  float blue=r.integer(0,255)/255.f, alpha=r.integer(0,255)/255.f;
  return {linear(red)*alpha,linear(green)*alpha,linear(blue)*alpha,alpha};
}
Pixel times(Pixel p,float f) { return {p.r*f,p.g*f,p.b*f,p.a*f}; }
void over(Pixel& d,Pixel s) {
  float inv=1-s.a;
  d={s.r+inv*d.r,s.g+inv*d.g,s.b+inv*d.b,s.a+inv*d.a};
}
struct Stop { double offset; Pixel color; };
struct Paint {
  int kind=0; Pixel solid; double x=0,y=0,u=0,v=0;
  std::vector<Stop> stops;
  Pixel at(double px,double py) const {
    if (!kind) return solid;
    double t=kind==1?((px-x)*(u-x)+(py-y)*(v-y))/((u-x)*(u-x)+(v-y)*(v-y)):
      std::hypot(px-x,py-y)/u;
    t=std::clamp(t,0.0,1.0);
    size_t i=1;
    while(i+1<stops.size() && t>stops[i].offset) ++i;
    const auto &a=stops[i-1], &b=stops[i];
    float f=float((t-a.offset)/(b.offset-a.offset));
    return {a.color.r+(b.color.r-a.color.r)*f,a.color.g+(b.color.g-a.color.g)*f,
      a.color.b+(b.color.b-a.color.b)*f,a.color.a+(b.color.a-a.color.a)*f};
  }
};
Paint paint(Reader& r) {
  Paint p; p.kind=r.integer(0,2);
  if (!p.kind) { p.solid=color(r); return p; }
  p.x=r.grid(); p.y=r.grid(); p.u=r.grid(); p.v=r.grid();
  if ((p.kind==1 && p.x==p.u && p.y==p.v) || (p.kind==2 && p.u<=0))
    throw std::runtime_error("degenerate gradient");
  int n=r.integer(2,32);
  for(int i=0;i<n;i++) {
    double off=r.unit();
    if ((i && off<=p.stops.back().offset) || (!i && off!=0) || (i==n-1 && off!=1))
      throw std::runtime_error("invalid gradient stops");
    p.stops.push_back({off,color(r)});
  }
  return p;
}
struct CairoSurface {
  cairo_surface_t* s;
  cairo_t* c;
  CairoSurface(int w,int h):s(cairo_image_surface_create(CAIRO_FORMAT_A8,w,h)),c(cairo_create(s)) {}
  ~CairoSurface() { cairo_destroy(c); cairo_surface_destroy(s); }
};
Mask path(Reader& r,int w,int h) {
  CairoSurface a(w,h);
  cairo_set_antialias(a.c,CAIRO_ANTIALIAS_GRAY);
  cairo_set_tolerance(a.c,0.1);
  cairo_set_fill_rule(a.c,CAIRO_FILL_RULE_WINDING);
  int n=r.integer(1,20000);
  for(int i=0;i<n;i++) {
    int k=r.integer(0,4);
    if (!i && k!=0) throw std::runtime_error("path must start with move");
    if(k==4) cairo_close_path(a.c);
    else {
      double x=r.grid(),y=r.grid();
      if(k==0) cairo_move_to(a.c,x,y);
      if(k==1) cairo_line_to(a.c,x,y);
      if(k==2) {
        double u=r.grid(),v=r.grid(),s=r.grid(),t=r.grid();
        cairo_curve_to(a.c,x,y,u,v,s,t);
      }
      if(k==3) {
        double u=r.grid(),v=r.grid(),cx,cy;
        cairo_get_current_point(a.c,&cx,&cy);
        cairo_curve_to(a.c,cx+(x-cx)*2/3,cy+(y-cy)*2/3,u+(x-u)*2/3,v+(y-v)*2/3,u,v);
      }
    }
  }
  cairo_set_source_rgba(a.c,1,1,1,1); cairo_fill(a.c); cairo_surface_flush(a.s);
  if(cairo_status(a.c)!=CAIRO_STATUS_SUCCESS || cairo_surface_status(a.s)!=CAIRO_STATUS_SUCCESS)
    throw std::runtime_error("path rasterization failed");
  Mask out(size_t(w)*h);
  auto data=cairo_image_surface_get_data(a.s); int stride=cairo_image_surface_get_stride(a.s);
  for(int y=0;y<h;y++) for(int x=0;x<w;x++) out[size_t(y)*w+x]=data[y*stride+x]/255.f;
  return out;
}
struct Point { double x,y,p,t; };
double quant(double x,double grid) { return std::nearbyint(x*grid)/grid; }
struct Engine {
  int w,h; size_t work=0,dabs=0; std::vector<Mask> masks;
  void charge(size_t count) {
    if(count>max_work-work) throw std::runtime_error("raster work limit exceeded");
    work+=count;
  }
  float mask(int id,size_t i) const { return id<0?1:masks.at(id)[i]; }
  int mask_ref(Reader& r) { return r.integer(-1,int(masks.size())-1); }
  void dab(Surface& layer,Point p,double base,double hardness,double ratio,float flow,
           float opacity,Pixel c,int mask_id,bool erase) {
    if(++dabs>1000000) throw std::runtime_error("dab limit exceeded");
    p.x=quant(p.x,1024); p.y=quant(p.y,1024); p.p=quant(p.p,65536);
    if(p.p==0) return;
    double radius=base*(ratio+(1-ratio)*p.p);
    if(radius<=0) return;
    int x0=int(std::clamp(std::floor(p.x-radius),0.0,double(w)));
    int y0=int(std::clamp(std::floor(p.y-radius),0.0,double(h)));
    int x1=int(std::clamp(std::ceil(p.x+radius),0.0,double(w)));
    int y1=int(std::clamp(std::ceil(p.y+radius),0.0,double(h)));
    charge(size_t(x1-x0)*(y1-y0)*4);
    for(int y=y0;y<y1;y++) for(int x=x0;x<x1;x++) {
      double coverage=0;
      for(double dy:{0.25,0.75}) for(double dx:{0.25,0.75}) {
        double d=std::hypot(x+dx-p.x,y+dy-p.y)/radius;
        coverage+=d<=hardness?1:(d>=1?0:(1-d)/(1-hardness));
      }
      size_t i=size_t(y)*w+x;
      float f=std::clamp(float(coverage*.25*p.p)*flow*opacity*mask(mask_id,i),0.f,1.f);
      if(erase) layer[i]=times(layer[i],1-f); else over(layer[i],times(c,f));
    }
  }
  void stroke(Reader& r,Surface& layer,bool erase) {
    int kind=r.integer(0,1);
    double hardness=r.unit(),spacing=r.grid(1.0/65536,16,65536);
    float flow=r.unit(); double ratio=r.unit();
    double radius=r.grid(1.0/1024,4096); float opacity=r.unit();
    Pixel c=color(r); int m=mask_ref(r); r.integer(0,2147483647); // seed, no jitter in v1
    if(!kind) hardness=1;
    int n=r.integer(1,5000); std::vector<Point> points;
    double total=0;
    for(int i=0;i<n;i++) {
      Point p{r.grid(),r.grid(),r.unit(),double(r.integer(0,2147483647))};
      if(i && p.t<points.back().t) throw std::runtime_error("decreasing stroke time");
      if(!points.empty()) total+=std::hypot(p.x-points.back().x,p.y-points.back().y);
      points.push_back(p);
    }
    double step=std::max(1.0/1024,radius*spacing);
    if(total/step+1>1000000-dabs) throw std::runtime_error("dab limit exceeded");
    dab(layer,points[0],radius,hardness,ratio,flow,opacity,c,m,erase);
    double travelled=0; size_t next=1;
    for(size_t i=1;i<points.size();i++) {
      auto a=points[i-1],b=points[i]; double len=std::hypot(b.x-a.x,b.y-a.y);
      if(len==0) continue;
      while(next*step<=travelled+len) {
        double f=(next*step-travelled)/len;
        dab(layer,{a.x+(b.x-a.x)*f,a.y+(b.y-a.y)*f,a.p+(b.p-a.p)*f,a.t+(b.t-a.t)*f},
          radius,hardness,ratio,flow,opacity,c,m,erase);
        ++next;
      }
      travelled+=len;
    }
  }
  Surface render(Reader& r) {
    w=r.integer(1,2048); h=r.integer(1,2048);
    if(size_t(w)*h>max_pixels) throw std::runtime_error("canvas pixel limit");
    Surface out(size_t(w)*h,color(r));
    int count=r.integer(0,128);
    if(size_t(count)*out.size()>33554432) throw std::runtime_error("mask memory limit");
    for(int i=0;i<count;i++) {
      int kind=r.integer(0,1);
      charge(out.size());
      if(!kind) masks.push_back(path(r,w,h));
      else {
        int aw=r.integer(1,2048),ah=r.integer(1,2048),x=r.integer(-1000000,1000000),y=r.integer(-1000000,1000000);
        std::ifstream asset("asset-"+std::to_string(i)+".raw",std::ios::binary);
        std::vector<unsigned char> bytes(size_t(aw)*ah);
        if(!asset.read(reinterpret_cast<char*>(bytes.data()),bytes.size()) || asset.peek()!=EOF)
          throw std::runtime_error("invalid bitmap mask asset");
        Mask mask(out.size());
        for(int sy=0;sy<ah;sy++) for(int sx=0;sx<aw;sx++)
          if(x+sx>=0 && y+sy>=0 && x+sx<w && y+sy<h)
            mask[size_t(y+sy)*w+x+sx]=bytes[size_t(sy)*aw+sx]/255.f;
        masks.push_back(std::move(mask));
      }
    }
    int layers=r.integer(0,128),operations=0;
    for(int l=0;l<layers;l++) {
      bool visible=r.integer(0,1); float opacity=r.unit(); int m=mask_ref(r);
      int n=r.integer(0,2000); operations+=n;
      if(operations>2000) throw std::runtime_error("operation limit");
      Surface layer(out.size());
      for(int i=0;i<n;i++) {
        int kind=r.integer(0,3);
        if(kind>=2) stroke(r,layer,kind==3);
        else {
          Mask coverage;
          int ref=-1;
          if(kind==0) coverage=path(r,w,h); else ref=mask_ref(r);
          if(kind==1 && ref<0) throw std::runtime_error("fill requires mask");
          Paint p=paint(r); float alpha=r.unit(); int opmask=mask_ref(r);
          charge(out.size());
          for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
            size_t k=size_t(y)*w+x;
            float cov=(kind==0?coverage[k]:mask(ref,k))*alpha*mask(opmask,k);
            over(layer[k],times(p.at(x+.5,y+.5),cov));
          }
        }
      }
      if(visible) {
        charge(out.size());
        for(size_t i=0;i<out.size();i++) over(out[i],times(layer[i],opacity*mask(m,i)));
      }
    }
    std::string tail;
    if(r.in>>tail) throw std::runtime_error("trailing request tokens");
    return out;
  }
};
unsigned char byte(float v) { return static_cast<unsigned char>(std::floor(std::clamp(v,0.f,1.f)*255+0.5f)); }
std::vector<unsigned char> rgba(const Surface& surface) {
  std::vector<unsigned char> out(surface.size()*4);
  for(size_t i=0;i<surface.size();i++) {
    Pixel p=surface[i]; unsigned char a=byte(p.a);
    out[i*4]=a?byte(srgb(p.r/p.a)):0; out[i*4+1]=a?byte(srgb(p.g/p.a)):0;
    out[i*4+2]=a?byte(srgb(p.b/p.a)):0; out[i*4+3]=a;
  }
  return out;
}
void png(const char* name,int w,int h,const std::vector<unsigned char>& pixels) {
  FILE* file=std::fopen(name,"wb"); if(!file) throw std::runtime_error("cannot open PNG output");
  png_structp p=png_create_write_struct(PNG_LIBPNG_VER_STRING,nullptr,nullptr,nullptr);
  png_infop info=p?png_create_info_struct(p):nullptr;
  if(!p || !info) { if(p) png_destroy_write_struct(&p,nullptr); std::fclose(file); throw std::runtime_error("PNG allocation"); }
  if(setjmp(png_jmpbuf(p))) { png_destroy_write_struct(&p,&info); std::fclose(file); throw std::runtime_error("PNG encoding failed"); }
  png_init_io(p,file);
  png_set_IHDR(p,info,w,h,8,PNG_COLOR_TYPE_RGBA,PNG_INTERLACE_NONE,PNG_COMPRESSION_TYPE_BASE,PNG_FILTER_TYPE_BASE);
  png_set_sRGB(p,info,PNG_sRGB_INTENT_RELATIVE); png_set_compression_level(p,6);
  png_set_filter(p,PNG_FILTER_TYPE_BASE,PNG_FILTER_SUB);
  png_write_info(p,info);
  for(int y=0;y<h;y++) png_write_row(p,const_cast<png_bytep>(pixels.data()+size_t(y)*w*4));
  png_write_end(p,info); png_destroy_write_struct(&p,&info);
  if(std::fclose(file)) throw std::runtime_error("PNG close failed");
}
std::vector<unsigned char> resize(const std::vector<unsigned char>& p,int w,int h,int x,int y,int cw,int ch,int ow,int oh) {
  std::vector<unsigned char> out(size_t(ow)*oh*4);
  for(int dy=0;dy<oh;dy++) for(int dx=0;dx<ow;dx++) {
    int sx=x+int((dx+.5)*cw/ow),sy=y+int((dy+.5)*ch/oh);
    std::copy_n(p.data()+(size_t(sy)*w+sx)*4,4,out.data()+(size_t(dy)*ow+dx)*4);
  }
  return out;
}
} // namespace
int main(int argc,char** argv) {
  using namespace raster;
  try {
    std::fesetround(FE_TONEAREST);
    if(argc==2 && std::string(argv[1])=="--crop") {
      Reader r;
      int x=r.integer(0,2047),y=r.integer(0,2047),w=r.integer(1,2048),h=r.integer(1,2048);
      int zoom=r.integer(1,4);
      std::string tail; if(r.in>>tail) throw std::runtime_error("trailing crop tokens");
      png_image input{}; input.version=PNG_IMAGE_VERSION;
      if(!png_image_begin_read_from_file(&input,"source.png")) throw std::runtime_error("invalid source PNG");
      if(input.width>2048 || input.height>2048 || x+w>int(input.width) || y+h>int(input.height)
         || size_t(w)*h*zoom*zoom>max_pixels) {
        png_image_free(&input); throw std::runtime_error("crop bounds limit");
      }
      input.format=PNG_FORMAT_RGBA;
      std::vector<unsigned char> pixels(PNG_IMAGE_SIZE(input));
      if(!png_image_finish_read(&input,nullptr,pixels.data(),0,nullptr)) {
        png_image_free(&input); throw std::runtime_error("PNG decode failed");
      }
      auto cropped=resize(pixels,input.width,input.height,x,y,w,h,w*zoom,h*zoom);
      png_image_free(&input);
      png("crop.png",w*zoom,h*zoom,cropped);
      return 0;
    }
    if(argc==2 && std::string(argv[1])=="--profile") {
      std::cout<<"raster-cairo-linear/v1 cairo="<<cairo_version_string()<<" libpng="<<png_get_libpng_ver(nullptr)
        <<" zlib="<<zlibVersion()<<" compiler="<<__VERSION__<<" float32 nearest no-fast-math fp-contract-off single-thread\n";
      return 0;
    }
    if(argc!=1) throw std::runtime_error("unexpected arguments");
    std::ifstream sizecheck("request.txt",std::ios::binary|std::ios::ate);
    if(!sizecheck || sizecheck.tellg()>8388608) throw std::runtime_error("request size limit");
    Reader r; if(r.integer(1,1)!=1) return 1;
    Engine e; auto pixels=rgba(e.render(r));
    png("observation.png",e.w,e.h,pixels);
    std::ofstream raw("pixels.rgba",std::ios::binary);
    raw.write(reinterpret_cast<const char*>(pixels.data()),pixels.size()); raw.close();
    if(!raw) throw std::runtime_error("raw output failed");
    int tw=std::min(e.w,256),th=std::max(1,int(std::floor(double(e.h)*tw/e.w+.5)));
    if(th>256) { th=256; tw=std::max(1,int(std::floor(double(e.w)*th/e.h+.5))); }
    png("thumbnail.png",tw,th,resize(pixels,e.w,e.h,0,0,e.w,e.h,tw,th));
    std::cout<<e.w<<" "<<e.h<<" "<<e.dabs<<" "<<e.work<<"\n";
  } catch(const std::exception& e) { std::cerr<<"raster: "<<e.what()<<"\n"; return 1; }
}
