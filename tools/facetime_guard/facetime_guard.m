#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <unistd.h>

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

      printf("RINGING\t%u\t%s\t%.1f\t%.1f\t%d\t%d\t%d\t%s\n",
             d.wid,
             d.owner,
             d.clickX,
             d.clickY,
             d.green,
             d.red,
             d.faceTimeHint ? 1 : 0,
             d.source);
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
