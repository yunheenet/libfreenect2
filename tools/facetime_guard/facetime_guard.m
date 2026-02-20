#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ImageIO/ImageIO.h>
#import <unistd.h>
#import <math.h>
#if __has_include(<Vision/Vision.h>)
#import <Vision/Vision.h>
#define FACETIME_GUARD_HAS_VISION 1
#else
#define FACETIME_GUARD_HAS_VISION 0
#endif

static const char *kCandidateOwners[] = {
  "FaceTime",
  "NotificationCenter",
  "UserNotificationCenter",
  "ControlCenter",
  "FaceTimeNotificationService",
  "FaceTimeNotificationViewBridgeService",
  "FaceTimeNotificationExtension"
};

static bool strContainsToken(NSString *source, const char *token)
{
  if(source == nil) return false;
  NSString *tok = [NSString stringWithUTF8String:token];
  return [source rangeOfString:tok options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static bool isCandidateOwner(NSString *owner)
{
  if(owner == nil) return false;
  for(size_t i = 0; i < sizeof(kCandidateOwners) / sizeof(kCandidateOwners[0]); ++i)
  {
    if(strContainsToken(owner, kCandidateOwners[i])) return true;
  }
  return false;
}

static bool hasFaceTimeHint(NSString *owner, NSString *name)
{
  if(strContainsToken(owner, "FaceTime") || strContainsToken(name, "FaceTime")) return true;
  if(strContainsToken(name, "영상 통화") || strContainsToken(name, "오디오 통화")) return true;
  if(strContainsToken(name, "Video Call") || strContainsToken(name, "Audio Call")) return true;
  return false;
}

static int greenLocalThreshold(void)
{
  const char *env = getenv("FACETIME_GUARD_GREEN_LOCAL_THRESHOLD");
  if(env == NULL || env[0] == '\0') return 850;
  int v = atoi(env);
  if(v < 100) v = 100;
  if(v > 50000) v = 50000;
  return v;
}

static double envDoubleOrDefault(const char *key, double def)
{
  const char *env = getenv(key);
  if(env == NULL || env[0] == '\0') return def;
  return atof(env);
}

static NSString *envStringOrNil(const char *key)
{
  const char *env = getenv(key);
  if(env == NULL || env[0] == '\0') return nil;
  return [NSString stringWithUTF8String:env];
}

static double fallbackOffsetX(void)
{
  return envDoubleOrDefault("FACETIME_GUARD_FALLBACK_OFFSET_X", 0.0);
}

static double fallbackOffsetY(void)
{
  return envDoubleOrDefault("FACETIME_GUARD_FALLBACK_OFFSET_Y", 0.0);
}

typedef struct
{
  int green;
  int red;
} ColorStats;

typedef struct
{
  bool found;
  double x;
  double y;
  int count;
} GreenScan;

typedef struct
{
  bool found;
  CGWindowID wid;
  CGRect bounds;
  char owner[128];
  int green;
  int red;
  bool faceTimeHint;
  double clickX;
  double clickY;
  char source[24];
  char caller[128];
} Detection;

static bool parseBoundsFromDict(CFDictionaryRef dict, CGRect *outRect)
{
  if(dict == NULL || outRect == NULL) return false;
  CGRect r;
  if(!CGRectMakeWithDictionaryRepresentation(dict, &r)) return false;
  *outRect = r;
  return true;
}

static ColorStats analyzeImageColors(CGImageRef src, bool topRightOnly)
{
  ColorStats stats = {0, 0};
  if(src == NULL) return stats;

  size_t width = CGImageGetWidth(src);
  size_t height = CGImageGetHeight(src);
  if(width == 0 || height == 0) return stats;

  size_t bytesPerRow = width * 4;
  uint8_t *buf = (uint8_t *)calloc(height, bytesPerRow);
  if(buf == NULL) return stats;

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buf, width, height, 8, bytesPerRow, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);

  if(ctx == NULL)
  {
    free(buf);
    return stats;
  }

  CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), src);

  size_t xStart = topRightOnly ? (size_t)(width * 0.50) : 0;
  size_t yEnd = topRightOnly ? (size_t)(height * 0.45) : height;
  if(yEnd < 1) yEnd = height;

  for(size_t y = 0; y < yEnd; ++y)
  {
    uint8_t *row = buf + (y * bytesPerRow);
    for(size_t x = xStart; x < width; ++x)
    {
      uint8_t *p = row + (x * 4);
      uint8_t r = p[0];
      uint8_t g = p[1];
      uint8_t b = p[2];

      if(g > 150 && r < 150 && b < 170 && (g - r) > 30) stats.green++;
      if(r > 170 && g < 145 && b < 155) stats.red++;
    }
  }

  CGContextRelease(ctx);
  free(buf);
  return stats;
}

static ColorStats analyzeWindowColors(CGWindowID wid, CGRect bounds)
{
  CGImageRef src = CGWindowListCreateImage(bounds,
                                           kCGWindowListOptionIncludingWindow,
                                           wid,
                                           kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
  if(src == NULL)
  {
    ColorStats z = {0, 0};
    return z;
  }

  ColorStats stats = analyzeImageColors(src, true);
  CGImageRelease(src);
  return stats;
}

static NSString *trimmed(NSString *s)
{
  if(s == nil) return nil;
  return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static bool isNoiseLine(NSString *line)
{
  if(line == nil || line.length == 0) return true;
  NSArray<NSString *> *tokens = @[
    @"FaceTime", @"영상 통화", @"오디오 통화", @"video call", @"audio call",
    @"수신", @"통화", @"받으", @"decline", @"accept", @"notification",
    @"open", @"file", @"edit", @"view", @"window", @"help", @"commit"
  ];
  for(NSString *t in tokens)
  {
    if([line rangeOfString:t options:NSCaseInsensitiveSearch].location != NSNotFound) return true;
  }
  return false;
}

static bool hasNameLikeChars(NSString *line)
{
  if(line == nil || line.length == 0) return false;
  NSRange r = [line rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]];
  if(r.location != NSNotFound) return true;
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[가-힣]" options:0 error:nil];
  if(re == nil) return false;
  return [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil;
}

static NSString *sanitizeCaller(NSString *raw)
{
  NSString *s = trimmed(raw);
  if(s == nil || s.length == 0) return nil;

  s = [s stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
  s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];

  NSArray<NSString *> *cutTokens = @[@"FaceTime", @"영상 통화", @"오디오 통화", @"Video Call", @"Audio Call"];
  for(NSString *token in cutTokens)
  {
    NSRange r = [s rangeOfString:token options:NSCaseInsensitiveSearch];
    if(r.location != NSNotFound && r.location > 0)
    {
      s = [s substringToIndex:r.location];
      s = trimmed(s);
      break;
    }
  }

  if(s == nil || s.length == 0) return nil;
  if(isNoiseLine(s)) return nil;
  if(!hasNameLikeChars(s)) return nil;
  if(s.length > 60) s = [s substringToIndex:60];
  return s;
}

static void setCallerToDetection(Detection *d, NSString *caller)
{
  if(d == NULL) return;
  d->caller[0] = '\0';
  NSString *safe = sanitizeCaller(caller);
  if(safe == nil) return;
  const char *c = [safe UTF8String];
  if(c == NULL) return;
  strncpy(d->caller, c, sizeof(d->caller) - 1);
  d->caller[sizeof(d->caller) - 1] = '\0';
}

static NSString *callerFromWindowName(NSString *name)
{
  NSString *s = sanitizeCaller(name);
  if(s != nil) return s;
  if(name == nil) return nil;

  NSArray<NSString *> *parts = [name componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  for(NSString *part in parts)
  {
    NSString *p = sanitizeCaller(part);
    if(p != nil) return p;
  }
  return nil;
}

static CGImageRef copyScreenImage(CGRect rect)
{
  return CGWindowListCreateImage(rect,
                                 kCGWindowListOptionOnScreenOnly,
                                 kCGNullWindowID,
                                 kCGWindowImageDefault | kCGWindowImageBestResolution);
}

static NSString *extractCallerFromWindowMetadata(bool debug)
{
  CGRect screen = CGDisplayBounds(CGMainDisplayID());
  CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if(arr == NULL) return nil;

  NSString *bestCaller = nil;
  int bestScore = -1;

  CFIndex count = CFArrayGetCount(arr);
  for(CFIndex i = 0; i < count; ++i)
  {
    CFDictionaryRef w = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
    if(w == NULL) continue;

    NSString *owner = (__bridge NSString *)CFDictionaryGetValue(w, kCGWindowOwnerName);
    if(!isCandidateOwner(owner)) continue;

    CFDictionaryRef bdict = (CFDictionaryRef)CFDictionaryGetValue(w, kCGWindowBounds);
    CGRect b;
    if(!parseBoundsFromDict(bdict, &b)) continue;
    if(b.size.width < 160 || b.size.height < 70) continue;

    double rightEdge = b.origin.x + b.size.width;
    if(rightEdge < screen.size.width * 0.45) continue;
    if(b.origin.y > screen.size.height * 0.65) continue;

    NSString *name = (__bridge NSString *)CFDictionaryGetValue(w, kCGWindowName);
    NSString *caller = callerFromWindowName(name);
    if(caller == nil) continue;

    int score = (int)(b.size.width + b.size.height);
    if(hasFaceTimeHint(owner, name)) score += 300;

    if(debug)
    {
      fprintf(stderr, "DEBUG meta-caller owner='%s' name='%s' caller='%s' score=%d\n",
              [[owner ?: @"" description] UTF8String],
              [[name ?: @"" description] UTF8String],
              [[caller ?: @"" description] UTF8String],
              score);
    }

    if(score > bestScore)
    {
      bestScore = score;
      bestCaller = caller;
    }
  }

  CFRelease(arr);
  return bestCaller;
}

#if FACETIME_GUARD_HAS_VISION
static NSString *callerFromImageOCR(CGImageRef image, bool debug)
{
  if(image == NULL) return nil;

  VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
  req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  req.usesLanguageCorrection = YES;
  req.minimumTextHeight = 0.03;
  if(@available(macOS 11.0, *))
  {
    req.recognitionLanguages = @[@"ko-KR", @"en-US"];
  }

  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
  NSError *err = nil;
  if(![handler performRequests:@[req] error:&err])
  {
    if(debug && err != nil)
    {
      fprintf(stderr, "DEBUG ocr error='%s'\n", [[err localizedDescription] UTF8String]);
    }
    return nil;
  }

  NSArray<VNRecognizedTextObservation *> *obs = req.results;
  if(obs.count == 0) return nil;

  NSArray<VNRecognizedTextObservation *> *sorted = [obs sortedArrayUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
    double ay = a.boundingBox.origin.y + a.boundingBox.size.height;
    double by = b.boundingBox.origin.y + b.boundingBox.size.height;
    if(fabs(ay - by) > 0.03) return (ay > by) ? NSOrderedAscending : NSOrderedDescending;
    if(fabs(a.boundingBox.origin.x - b.boundingBox.origin.x) > 0.01)
    {
      return (a.boundingBox.origin.x < b.boundingBox.origin.x) ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
  }];

  NSString *best = nil;
  int bestScore = -9999;

  for(VNRecognizedTextObservation *o in sorted)
  {
    NSArray<VNRecognizedText *> *tops = [o topCandidates:3];
    for(VNRecognizedText *t in tops)
    {
      if(t == nil) continue;
      NSString *cand = sanitizeCaller(t.string);
      int score = 0;
      if(cand != nil)
      {
        bool hasHangul = [cand rangeOfString:@"[가-힣]" options:NSRegularExpressionSearch].location != NSNotFound;
        bool hasDigit = [cand rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound;
        bool hasPunct = [cand rangeOfCharacterFromSet:[NSCharacterSet punctuationCharacterSet]].location != NSNotFound;
        if(hasHangul) score += 120;
        if((int)cand.length >= 2 && (int)cand.length <= 8) score += 30;
        if(o.boundingBox.origin.y > 0.45) score += 20;
        if(hasDigit) score -= 40;
        if(hasPunct) score -= 40;
        score += (int)round(t.confidence * 20.0);
      }

      if(debug)
      {
        fprintf(stderr, "DEBUG ocr line='%s' x=%.2f y=%.2f h=%.2f conf=%.2f cand='%s' score=%d\n",
                [[t.string ?: @"" description] UTF8String],
                o.boundingBox.origin.x,
                o.boundingBox.origin.y,
                o.boundingBox.size.height,
                t.confidence,
                [[cand ?: @"" description] UTF8String],
                score);
      }

      if(cand != nil && score > bestScore)
      {
        bestScore = score;
        best = cand;
      }
    }
  }

  if(bestScore < 20) return nil;
  return best;
}
#endif

static NSString *extractCallerFromWindowImage(CGWindowID wid, CGRect bounds, bool debug)
{
#if FACETIME_GUARD_HAS_VISION
  CGImageRef img = CGWindowListCreateImage(bounds,
                                           kCGWindowListOptionIncludingWindow,
                                           wid,
                                           kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
  if(img == NULL) return nil;
  NSString *caller = callerFromImageOCR(img, debug);
  CGImageRelease(img);
  return caller;
#else
  (void)wid;
  (void)bounds;
  (void)debug;
  return nil;
#endif
}

static CGRect clampRectToScreen(CGRect rect, CGRect screen)
{
  if(rect.origin.x < screen.origin.x) rect.origin.x = screen.origin.x;
  if(rect.origin.y < screen.origin.y) rect.origin.y = screen.origin.y;
  double maxX = screen.origin.x + screen.size.width;
  double maxY = screen.origin.y + screen.size.height;
  if(rect.origin.x + rect.size.width > maxX) rect.size.width = maxX - rect.origin.x;
  if(rect.origin.y + rect.size.height > maxY) rect.size.height = maxY - rect.origin.y;
  if(rect.size.width < 1) rect.size.width = 1;
  if(rect.size.height < 1) rect.size.height = 1;
  return rect;
}

static NSString *extractCallerFromRectWithOCR(CGRect rect, bool debug, const char *label)
{
#if FACETIME_GUARD_HAS_VISION
  CGRect screen = CGDisplayBounds(CGMainDisplayID());
  CGRect roi = clampRectToScreen(rect, screen);
  CGImageRef img = copyScreenImage(roi);
  if(img == NULL) return nil;

  NSString *caller = callerFromImageOCR(img, debug);
  if(debug)
  {
    fprintf(stderr, "DEBUG fallback ocr %s roi=(%.0f,%.0f %.0fx%.0f) caller='%s'\n",
            label ? label : "-",
            roi.origin.x, roi.origin.y, roi.size.width, roi.size.height,
            [[caller ?: @"" description] UTF8String]);
  }
  CGImageRelease(img);
  return caller;
#else
  (void)rect;
  (void)debug;
  (void)label;
  return nil;
#endif
}

static void dumpRoiImage(CGRect rect, const char *label, bool debug)
{
  NSString *dir = envStringOrNil("FACETIME_GUARD_DEBUG_ROI_DIR");
  if(dir == nil) return;

  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *mkErr = nil;
  if(![fm fileExistsAtPath:dir])
  {
    if(![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&mkErr])
    {
      if(debug && mkErr != nil)
      {
        fprintf(stderr, "DEBUG roi-dump mkdir failed path='%s' err='%s'\n",
                [dir UTF8String], [[mkErr localizedDescription] UTF8String]);
      }
      return;
    }
  }

  CGRect screen = CGDisplayBounds(CGMainDisplayID());
  CGRect roi = clampRectToScreen(rect, screen);
  CGImageRef img = copyScreenImage(roi);
  if(img == NULL) return;

  NSString *name = [NSString stringWithFormat:@"%s.png", label ? label : "roi"];
  NSString *path = [dir stringByAppendingPathComponent:name];
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
  if(dest != NULL)
  {
    CGImageDestinationAddImage(dest, img, NULL);
    bool ok = CGImageDestinationFinalize(dest);
    if(debug)
    {
      fprintf(stderr, "DEBUG roi-dump %s path='%s' rect=(%.0f,%.0f %.0fx%.0f) ok=%d\n",
              label ? label : "roi", [path UTF8String],
              roi.origin.x, roi.origin.y, roi.size.width, roi.size.height,
              ok ? 1 : 0);
    }
    CFRelease(dest);
  }
  CGImageRelease(img);
}

static NSString *extractCallerNearFallbackPoint(double clickX, double clickY, bool debug)
{
#if FACETIME_GUARD_HAS_VISION
  CGRect screen = CGDisplayBounds(CGMainDisplayID());

  // First pass: a tight name-band near the green accept button.
  double nameW = envDoubleOrDefault("FACETIME_GUARD_CALLER_NAME_W", 380);
  double nameH = envDoubleOrDefault("FACETIME_GUARD_CALLER_NAME_H", 105);
  double nameOffsetX = envDoubleOrDefault("FACETIME_GUARD_CALLER_NAME_OFFSET_X", 330);
  double nameOffsetY = envDoubleOrDefault("FACETIME_GUARD_CALLER_NAME_OFFSET_Y", 34);
  if(nameW < 240) nameW = 240;
  if(nameH < 70) nameH = 70;
  if(nameW > screen.size.width * 0.60) nameW = screen.size.width * 0.60;
  if(nameH > screen.size.height * 0.30) nameH = screen.size.height * 0.30;

  CGRect nameRect = CGRectMake(clickX - nameOffsetX, clickY - nameOffsetY, nameW, nameH);
  if(debug)
  {
    fprintf(stderr, "GUIDE caller-name rect=(%.0f,%.0f %.0fx%.0f) click=(%.1f,%.1f)\n",
            nameRect.origin.x, nameRect.origin.y, nameRect.size.width, nameRect.size.height, clickX, clickY);
  }
  dumpRoiImage(nameRect, "caller_name", debug);
  CGRect badgeRect = CGRectMake(nameRect.origin.x + (nameRect.size.width * 0.02),
                                nameRect.origin.y + (nameRect.size.height * 0.08),
                                nameRect.size.width * 0.34,
                                nameRect.size.height * 0.82);
  if(debug)
  {
    fprintf(stderr, "GUIDE caller-badge rect=(%.0f,%.0f %.0fx%.0f)\n",
            badgeRect.origin.x, badgeRect.origin.y, badgeRect.size.width, badgeRect.size.height);
  }
  dumpRoiImage(badgeRect, "caller_badge", debug);
  NSString *caller = extractCallerFromRectWithOCR(badgeRect, debug, "badge");
  if(caller != nil) return caller;

  CGRect titleRect = CGRectMake(nameRect.origin.x + (nameRect.size.width * 0.28),
                                nameRect.origin.y + (nameRect.size.height * 0.00),
                                nameRect.size.width * 0.40,
                                nameRect.size.height * 0.50);
  if(debug)
  {
    fprintf(stderr, "GUIDE caller-title rect=(%.0f,%.0f %.0fx%.0f)\n",
            titleRect.origin.x, titleRect.origin.y, titleRect.size.width, titleRect.size.height);
  }
  dumpRoiImage(titleRect, "caller_title", debug);
  caller = extractCallerFromRectWithOCR(titleRect, debug, "title");
  if(caller != nil) return caller;

  caller = extractCallerFromRectWithOCR(nameRect, debug, "name");
  if(caller != nil) return caller;

  double cardW = envDoubleOrDefault("FACETIME_GUARD_CALLER_ROI_W", 560);
  double cardH = envDoubleOrDefault("FACETIME_GUARD_CALLER_ROI_H", 130);
  if(cardW < 360) cardW = 360;
  if(cardH < 90) cardH = 90;
  if(cardW > screen.size.width * 0.70) cardW = screen.size.width * 0.70;
  if(cardH > screen.size.height * 0.45) cardH = screen.size.height * 0.45;

  double anchorX = envDoubleOrDefault("FACETIME_GUARD_CALLER_ROI_ANCHOR_X", 0.84);
  double anchorY = envDoubleOrDefault("FACETIME_GUARD_CALLER_ROI_ANCHOR_Y", 0.35);

  CGRect r1 = CGRectMake(clickX - (cardW * anchorX), clickY - (cardH * anchorY), cardW, cardH);
  if(debug)
  {
    fprintf(stderr, "GUIDE caller-r1 rect=(%.0f,%.0f %.0fx%.0f) click=(%.1f,%.1f)\n",
            r1.origin.x, r1.origin.y, r1.size.width, r1.size.height, clickX, clickY);
  }
  dumpRoiImage(r1, "caller_r1", debug);
  caller = extractCallerFromRectWithOCR(r1, debug, "r1");
  if(caller != nil) return caller;

  CGRect r2 = CGRectMake(clickX - (cardW * 1.00), clickY - (cardH * 0.45), cardW * 1.30, cardH * 1.50);
  if(debug)
  {
    fprintf(stderr, "GUIDE caller-r2 rect=(%.0f,%.0f %.0fx%.0f) click=(%.1f,%.1f)\n",
            r2.origin.x, r2.origin.y, r2.size.width, r2.size.height, clickX, clickY);
  }
  dumpRoiImage(r2, "caller_r2", debug);
  caller = extractCallerFromRectWithOCR(r2, debug, "r2");
  if(caller != nil) return caller;

  CGRect r3 = CGRectMake(screen.origin.x + screen.size.width * 0.50, screen.origin.y, screen.size.width * 0.50, screen.size.height * 0.45);
  if(debug)
  {
    fprintf(stderr, "GUIDE caller-r3 rect=(%.0f,%.0f %.0fx%.0f)\n",
            r3.origin.x, r3.origin.y, r3.size.width, r3.size.height);
  }
  dumpRoiImage(r3, "caller_r3", debug);
  caller = extractCallerFromRectWithOCR(r3, debug, "r3");
  return caller;
#else
  (void)clickX;
  (void)clickY;
  (void)debug;
  return nil;
#endif
}

static GreenScan scanGreenButtonTopRight(bool debug)
{
  GreenScan gs = {0};

  CGRect screen = CGDisplayBounds(CGMainDisplayID());
  CGRect roi = CGRectMake(screen.origin.x + screen.size.width * 0.55,
                          screen.origin.y,
                          screen.size.width * 0.45,
                          screen.size.height * 0.45);

  CGImageRef img = CGWindowListCreateImage(roi,
                                           kCGWindowListOptionOnScreenOnly,
                                           kCGNullWindowID,
                                           kCGWindowImageDefault | kCGWindowImageBestResolution);
  if(img == NULL) return gs;

  size_t width = CGImageGetWidth(img);
  size_t height = CGImageGetHeight(img);
  if(width == 0 || height == 0)
  {
    CGImageRelease(img);
    return gs;
  }

  size_t bytesPerRow = width * 4;
  double scaleX = roi.size.width / (double)width;
  double scaleY = roi.size.height / (double)height;
  if(scaleX <= 0.0) scaleX = 1.0;
  if(scaleY <= 0.0) scaleY = 1.0;

  uint8_t *buf = (uint8_t *)calloc(height, bytesPerRow);
  if(buf == NULL)
  {
    CGImageRelease(img);
    return gs;
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buf, width, height, 8, bytesPerRow, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if(ctx == NULL)
  {
    free(buf);
    CGImageRelease(img);
    return gs;
  }

  CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), img);

  size_t pixelCount = width * height;
  uint8_t *mask = (uint8_t *)calloc(pixelCount, sizeof(uint8_t));
  if(mask == NULL)
  {
    CGContextRelease(ctx);
    free(buf);
    CGImageRelease(img);
    return gs;
  }

  int totalGreen = 0;

  for(size_t y = 0; y < height; ++y)
  {
    uint8_t *row = buf + (y * bytesPerRow);
    for(size_t x = 0; x < width; ++x)
    {
      uint8_t *p = row + (x * 4);
      uint8_t r = p[0];
      uint8_t g = p[1];
      uint8_t b = p[2];

      if(g > 145 && r < 145 && b < 170 && (g - r) > 35)
      {
        totalGreen++;
        mask[y * width + x] = 1;
      }
    }
  }

  if(totalGreen <= 0)
  {
    free(mask);
    CGContextRelease(ctx);
    free(buf);
    CGImageRelease(img);
    return gs;
  }

  // Integral image: detect dense local green patch instead of scattered green pixels.
  size_t iw = width + 1;
  size_t ih = height + 1;
  int *integral = (int *)calloc(iw * ih, sizeof(int));
  if(integral == NULL)
  {
    free(mask);
    CGContextRelease(ctx);
    free(buf);
    CGImageRelease(img);
    return gs;
  }

  for(size_t y = 1; y <= height; ++y)
  {
    int rowSum = 0;
    for(size_t x = 1; x <= width; ++x)
    {
      rowSum += mask[(y - 1) * width + (x - 1)];
      integral[y * iw + x] = integral[(y - 1) * iw + x] + rowSum;
    }
  }

  int winW = (int)(width * 0.14);
  int winH = (int)(height * 0.10);
  if(winW < 120) winW = 120;
  if(winH < 70) winH = 70;
  if(winW >= (int)width) winW = (int)width - 1;
  if(winH >= (int)height) winH = (int)height - 1;

  int bestCount = 0;
  int bestX = 0;
  int bestY = 0;
  for(int y = 0; y <= (int)height - winH; y += 2)
  {
    for(int x = 0; x <= (int)width - winW; x += 2)
    {
      int x1 = x;
      int y1 = y;
      int x2 = x + winW;
      int y2 = y + winH;
      int c = integral[y2 * iw + x2] - integral[y1 * iw + x2] - integral[y2 * iw + x1] + integral[y1 * iw + x1];
      if(c > bestCount)
      {
        bestCount = c;
        bestX = x;
        bestY = y;
      }
    }
  }

  // Refine click point from window center to green-pixel centroid inside best window.
  double refinedX = bestX + (winW * 0.5);
  double refinedY = bestY + (winH * 0.5);
  long sumX = 0;
  long sumY = 0;
  int refinedCount = 0;
  for(int y = bestY; y < bestY + winH; ++y)
  {
    size_t rowBase = (size_t)y * width;
    for(int x = bestX; x < bestX + winW; ++x)
    {
      if(mask[rowBase + (size_t)x] != 0)
      {
        sumX += x;
        sumY += y;
        refinedCount++;
      }
    }
  }
  if(refinedCount > 0)
  {
    refinedX = (double)sumX / (double)refinedCount;
    refinedY = (double)sumY / (double)refinedCount;
  }

  free(integral);
  free(mask);
  CGContextRelease(ctx);
  free(buf);
  CGImageRelease(img);

  int threshold = greenLocalThreshold();

  if(debug)
  {
    fprintf(stderr, "DEBUG green-scan total=%d local-best=%d threshold=%d win=%dx%d pos=(%d,%d) centroid=(%.1f,%.1f) centroidN=%d roi=(%.0f,%.0f %.0fx%.0f)\n",
            totalGreen, bestCount, threshold, winW, winH, bestX, bestY, refinedX, refinedY, refinedCount,
            roi.origin.x, roi.origin.y, roi.size.width, roi.size.height);
  }

  if(bestCount < threshold) return gs;

  gs.found = true;
  gs.count = bestCount;
  gs.x = roi.origin.x + (refinedX * scaleX);
  gs.y = roi.origin.y + (refinedY * scaleY);
  return gs;
}

static bool helperPidPresent(void)
{
  FILE *fp = popen("pgrep -f 'FaceTimeNotificationService|FaceTimeNotificationViewBridgeService|FaceTimeNotificationExtension' 2>/dev/null", "r");
  if(fp == NULL) return false;

  char line[64];
  bool present = (fgets(line, sizeof(line), fp) != NULL);
  pclose(fp);
  return present;
}

static Detection detectIncomingCallFromWindows(bool debug)
{
  Detection best;
  memset(&best, 0, sizeof(best));

  CGRect screen = CGDisplayBounds(CGMainDisplayID());
  CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if(arr == NULL) return best;

  CFIndex count = CFArrayGetCount(arr);
  int bestScore = -1;

  for(CFIndex i = 0; i < count; ++i)
  {
    CFDictionaryRef w = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
    if(w == NULL) continue;

    NSString *owner = (__bridge NSString *)CFDictionaryGetValue(w, kCGWindowOwnerName);
    if(!isCandidateOwner(owner)) continue;

    CFDictionaryRef bdict = (CFDictionaryRef)CFDictionaryGetValue(w, kCGWindowBounds);
    CGRect b;
    if(!parseBoundsFromDict(bdict, &b)) continue;

    if(b.size.width < 180 || b.size.height < 80) continue;

    double rightEdge = b.origin.x + b.size.width;
    if(rightEdge < screen.size.width * 0.55) continue;
    if(b.origin.y > screen.size.height * 0.60) continue;

    NSNumber *widNum = (__bridge NSNumber *)CFDictionaryGetValue(w, kCGWindowNumber);
    if(widNum == nil) continue;

    NSString *name = (__bridge NSString *)CFDictionaryGetValue(w, kCGWindowName);
    bool hint = hasFaceTimeHint(owner, name);

    ColorStats cs = analyzeWindowColors((CGWindowID)[widNum unsignedIntValue], b);

    if(debug)
    {
      fprintf(stderr, "DEBUG win owner='%s' name='%s' wid=%u bounds=(%.0f,%.0f %.0fx%.0f) g=%d r=%d hint=%d\n",
              [[owner ?: @"" description] UTF8String],
              [[name ?: @"" description] UTF8String],
              (unsigned)[widNum unsignedIntValue],
              b.origin.x, b.origin.y, b.size.width, b.size.height,
              cs.green, cs.red, hint ? 1 : 0);
    }

    bool ringingLike = (cs.green > 260 && cs.red > 220) || (hint && cs.green > 210 && cs.red > 90);
    if(!ringingLike) continue;

    int score = cs.green + cs.red + (hint ? 220 : 0);
    if(score > bestScore)
    {
      bestScore = score;
      best.found = true;
      best.wid = (CGWindowID)[widNum unsignedIntValue];
      best.bounds = b;
      best.green = cs.green;
      best.red = cs.red;
      best.faceTimeHint = hint;
      best.clickX = b.origin.x + b.size.width * 0.86;
      best.clickY = b.origin.y + b.size.height * 0.13;
      strncpy(best.source, "WINDOW", sizeof(best.source) - 1);
      const char *o = [owner UTF8String];
      if(o == NULL) o = "";
      strncpy(best.owner, o, sizeof(best.owner) - 1);
      best.owner[sizeof(best.owner) - 1] = '\0';

      NSString *caller = callerFromWindowName(name);
      if(caller == nil)
      {
        caller = extractCallerFromWindowImage(best.wid, best.bounds, debug);
      }
      setCallerToDetection(&best, caller);
    }
  }

  CFRelease(arr);
  return best;
}

static Detection detectIncomingCall(bool debug)
{
  Detection d = detectIncomingCallFromWindows(debug);
  if(d.found) return d;

  bool pid = helperPidPresent();
  GreenScan gs = scanGreenButtonTopRight(debug);

  if(debug)
  {
    fprintf(stderr, "DEBUG fallback pid=%d greenFound=%d count=%d\n", pid ? 1 : 0, gs.found ? 1 : 0, gs.count);
  }

  if(pid && gs.found)
  {
    Detection fb;
    memset(&fb, 0, sizeof(fb));
    fb.found = true;
    fb.wid = 0;
    fb.green = gs.count;
    fb.red = 0;
    fb.faceTimeHint = true;
    fb.clickX = gs.x + fallbackOffsetX();
    fb.clickY = gs.y + fallbackOffsetY();
    strncpy(fb.owner, "FaceTimeNotificationProcess", sizeof(fb.owner) - 1);
    strncpy(fb.source, "PID+GREEN", sizeof(fb.source) - 1);
    NSString *caller = extractCallerFromWindowMetadata(debug);
    if(caller == nil)
    {
      caller = extractCallerNearFallbackPoint(fb.clickX, fb.clickY, debug);
    }
    setCallerToDetection(&fb, caller);
    return fb;
  }

  return d;
}

static bool postLeftClick(double x, double y)
{
  CGPoint p = CGPointMake(x, y);
  CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
  CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, p, kCGMouseButtonLeft);
  CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, p, kCGMouseButtonLeft);

  if(move == NULL || down == NULL || up == NULL)
  {
    if(move) CFRelease(move);
    if(down) CFRelease(down);
    if(up) CFRelease(up);
    return false;
  }

  CGEventPost(kCGHIDEventTap, move);
  usleep(40000);
  CGEventPost(kCGHIDEventTap, down);
  usleep(40000);
  CGEventPost(kCGHIDEventTap, up);

  CFRelease(move);
  CFRelease(down);
  CFRelease(up);
  return true;
}

static void usage(const char *prog)
{
  fprintf(stderr,
          "Usage:\n"
          "  %s --detect\n"
          "  %s --debug-detect\n"
          "  %s --click X Y\n"
          "  %s --detect-and-click\n",
          prog, prog, prog, prog);
}

int main(int argc, const char *argv[])
{
  @autoreleasepool
  {
    if(argc < 2)
    {
      usage(argv[0]);
      return 2;
    }

    if(strcmp(argv[1], "--detect") == 0 || strcmp(argv[1], "--debug-detect") == 0)
    {
      bool debug = (strcmp(argv[1], "--debug-detect") == 0);
      Detection d = detectIncomingCall(debug);
      if(!d.found)
      {
        printf("IDLE\n");
        return 1;
      }

      printf("RINGING\t%u\t%s\t%.1f\t%.1f\t%d\t%d\t%d\t%s\t%s\n",
             d.wid,
             d.owner,
             d.clickX,
             d.clickY,
             d.green,
             d.red,
             d.faceTimeHint ? 1 : 0,
             d.source,
             d.caller[0] ? d.caller : "UNKNOWN");
      return 0;
    }

    if(strcmp(argv[1], "--click") == 0)
    {
      if(argc < 4)
      {
        usage(argv[0]);
        return 2;
      }

      double x = atof(argv[2]);
      double y = atof(argv[3]);
      if(!postLeftClick(x, y))
      {
        fprintf(stderr, "Failed to post click event.\n");
        return 1;
      }
      printf("CLICKED\t%.1f\t%.1f\n", x, y);
      return 0;
    }

    if(strcmp(argv[1], "--detect-and-click") == 0)
    {
      Detection d = detectIncomingCall(false);
      if(!d.found)
      {
        printf("IDLE\n");
        return 1;
      }

      if(!postLeftClick(d.clickX, d.clickY))
      {
        fprintf(stderr, "Detected but failed click.\n");
        return 1;
      }
      printf("CLICKED\t%u\t%s\t%.1f\t%.1f\t%s\n", d.wid, d.owner, d.clickX, d.clickY, d.source);
      return 0;
    }

    usage(argv[0]);
    return 2;
  }
}
