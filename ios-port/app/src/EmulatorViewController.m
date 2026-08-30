// EmulatorViewController.m — the in-game screen and its on-screen gamepad.
//
// Everything for this screen lives here:
//   V3KMetalSurfaceView   — a UIView whose backing layer IS a CAMetalLayer, so
//                           the native core can render straight into it.
//   V3KGamepadButton      — a custom-drawn, touch-tracking button (face glyph or
//                           text pill). Reports a V3KButton bit on press/release.
//   V3KDPadView           — a multi-touch directional pad (up/down/left/right,
//                           diagonals allowed).
//   V3KThumbstickView     — a draggable analog knob returning x/y in [-1, 1].
//   Vita3KControlsOverlay — lays the above out with frame math, keeps the pooled
//                           uint32_t pressed mask, and forwards everything to
//                           [Vita3KCore shared].
//
// The overlay is semi-transparent (opacity from NSUserDefaults "v3k.controlsOpacity",
// default 0.85) and only intercepts touches that land on an actual control —
// touches on empty space are forwarded to the core as front-panel touchscreen
// input.
#import "EmulatorViewController.h"
#import "Theme.h"
#import "Vita3KCore.h"
#import <QuartzCore/CAMetalLayer.h>

#pragma mark - V3KMetalSurfaceView

/// A view whose backing layer is a CAMetalLayer. The core renders into it.
@interface V3KMetalSurfaceView : UIView
@end

@implementation V3KMetalSurfaceView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        self.layer.backgroundColor = [UIColor blackColor].CGColor;
        CAMetalLayer *ml = (CAMetalLayer *)self.layer;
        ml.opaque = YES;
        ml.framebufferOnly = YES;
        ml.contentsScale = UIScreen.mainScreen.scale;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    ml.contentsScale = scale;
    ml.drawableSize = CGSizeMake(self.bounds.size.width * scale,
                                 self.bounds.size.height * scale);
}
@end

#pragma mark - V3KGamepadButton

typedef NS_ENUM(NSInteger, V3KBtnStyle) {
    V3KBtnStyleFace = 0,   // circular, PS face glyph
    V3KBtnStylePill,       // rounded pill, text label (L / R / START / SELECT)
};

typedef NS_ENUM(NSInteger, V3KGlyph) {
    V3KGlyphNone = 0,
    V3KGlyphTriangle,
    V3KGlyphCircle,
    V3KGlyphCross,
    V3KGlyphSquare,
};

/// One discrete gamepad button. Owns its own touch tracking and reports its
/// V3KButton mask via onPressChanged(mask, pressed).
@interface V3KGamepadButton : UIView
@property (nonatomic, assign) uint32_t buttonMask;
@property (nonatomic, assign) V3KBtnStyle style;
@property (nonatomic, assign) V3KGlyph glyph;
@property (nonatomic, copy, nullable) NSString *text;
@property (nonatomic, strong) UIColor *accentColor;
@property (nonatomic, assign, getter=isPressed) BOOL pressed;
@property (nonatomic, copy, nullable) void (^onPressChanged)(uint32_t mask, BOOL pressed);
@end

@implementation V3KGamepadButton

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = NO;
        _accentColor = V3KGold();
        _style = V3KBtnStyleFace;
        _glyph = V3KGlyphNone;
    }
    return self;
}

- (void)setPressed:(BOOL)pressed {
    if (_pressed == pressed) return;
    _pressed = pressed;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGRect b = CGRectInset(self.bounds, 2.0, 2.0);

    UIColor *fill = self.pressed ? [self.accentColor colorWithAlphaComponent:0.92]
                                 : [UIColor colorWithWhite:0.10 alpha:0.55];
    UIColor *stroke = self.pressed ? [UIColor whiteColor]
                                   : [self.accentColor colorWithAlphaComponent:0.85];
    UIColor *content = self.pressed ? V3KBackground() : self.accentColor;

    UIBezierPath *shape;
    if (self.style == V3KBtnStyleFace) {
        shape = [UIBezierPath bezierPathWithOvalInRect:b];
    } else {
        shape = [UIBezierPath bezierPathWithRoundedRect:b
                                           cornerRadius:MIN(b.size.height, b.size.width) * 0.30];
    }
    [fill setFill];
    [shape fill];
    shape.lineWidth = 2.0;
    [stroke setStroke];
    [shape stroke];

    if (self.style == V3KBtnStylePill || self.glyph == V3KGlyphNone) {
        NSString *label = self.text ?: @"";
        CGFloat fontSize = MIN(b.size.height * 0.5, 17.0);
        if (label.length > 3) fontSize = MIN(b.size.height * 0.42, 13.0);
        UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightHeavy];
        NSDictionary *attrs = @{ NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: content };
        CGSize sz = [label sizeWithAttributes:attrs];
        CGPoint org = CGPointMake(CGRectGetMidX(b) - sz.width / 2.0,
                                  CGRectGetMidY(b) - sz.height / 2.0);
        [label drawAtPoint:org withAttributes:attrs];
        return;
    }

    // PS face glyph, drawn centered.
    CGFloat cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    CGFloat r = MIN(b.size.width, b.size.height) * 0.24;
    CGContextSetStrokeColorWithColor(ctx, content.CGColor);
    CGContextSetLineWidth(ctx, MAX(2.5, r * 0.34));
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    switch (self.glyph) {
        case V3KGlyphTriangle: {
            CGContextMoveToPoint(ctx, cx, cy - r * 1.05);
            CGContextAddLineToPoint(ctx, cx + r * 0.95, cy + r * 0.72);
            CGContextAddLineToPoint(ctx, cx - r * 0.95, cy + r * 0.72);
            CGContextClosePath(ctx);
            CGContextStrokePath(ctx);
            break;
        }
        case V3KGlyphCircle: {
            CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2.0, r * 2.0));
            break;
        }
        case V3KGlyphCross: {
            CGFloat d = r * 0.85;
            CGContextMoveToPoint(ctx, cx - d, cy - d);
            CGContextAddLineToPoint(ctx, cx + d, cy + d);
            CGContextMoveToPoint(ctx, cx - d, cy + d);
            CGContextAddLineToPoint(ctx, cx + d, cy - d);
            CGContextStrokePath(ctx);
            break;
        }
        case V3KGlyphSquare: {
            CGFloat d = r * 0.82;
            CGContextStrokeRect(ctx, CGRectMake(cx - d, cy - d, d * 2.0, d * 2.0));
            break;
        }
        default:
            break;
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.pressed = YES;
    if (self.onPressChanged) self.onPressChanged(self.buttonMask, YES);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.pressed = NO;
    if (self.onPressChanged) self.onPressChanged(self.buttonMask, NO);
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.pressed = NO;
    if (self.onPressChanged) self.onPressChanged(self.buttonMask, NO);
}

@end

#pragma mark - V3KDPadView

/// A directional pad. Multi-touch aware; reports the union of held directions
/// (Up/Down/Left/Right, diagonals allowed) as a V3KButton mask.
@interface V3KDPadView : UIView
@property (nonatomic, assign) uint32_t directions;   // current held mask
@property (nonatomic, copy, nullable) void (^onDirectionsChanged)(uint32_t mask);
@end

@implementation V3KDPadView {
    NSMutableSet<UITouch *> *_touches;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        _touches = [NSMutableSet set];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGRect b = self.bounds;
    CGFloat cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    CGFloat arm = MIN(b.size.width, b.size.height) * 0.5;
    CGFloat thick = arm * 0.62;

    // Plus-shaped base.
    UIBezierPath *plus = [UIBezierPath bezierPath];
    CGRect vert = CGRectMake(cx - thick / 2.0, cy - arm, thick, arm * 2.0);
    CGRect horz = CGRectMake(cx - arm, cy - thick / 2.0, arm * 2.0, thick);
    [plus appendPath:[UIBezierPath bezierPathWithRoundedRect:vert cornerRadius:thick * 0.28]];
    [plus appendPath:[UIBezierPath bezierPathWithRoundedRect:horz cornerRadius:thick * 0.28]];
    [[UIColor colorWithWhite:0.10 alpha:0.55] setFill];
    [plus fill];
    plus.lineWidth = 2.0;
    [[V3KGold() colorWithAlphaComponent:0.75] setStroke];
    [plus stroke];

    // Direction chevrons; gold when active.
    CGFloat t = arm * 0.30;                 // chevron half-size
    CGFloat edge = arm * 0.66;              // distance from center
    void (^chevron)(uint32_t, CGPoint, CGPoint, CGPoint) =
        ^(uint32_t bit, CGPoint p0, CGPoint p1, CGPoint p2) {
        BOOL on = (self.directions & bit) != 0;
        UIColor *c = on ? V3KGold() : [V3KSubtext() colorWithAlphaComponent:0.55];
        [c setFill];
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:p0];
        [tri addLineToPoint:p1];
        [tri addLineToPoint:p2];
        [tri closePath];
        [tri fill];
    };
    chevron(V3KBtnUp,    CGPointMake(cx, cy - edge - t), CGPointMake(cx - t, cy - edge + t * 0.4), CGPointMake(cx + t, cy - edge + t * 0.4));
    chevron(V3KBtnDown,  CGPointMake(cx, cy + edge + t), CGPointMake(cx - t, cy + edge - t * 0.4), CGPointMake(cx + t, cy + edge - t * 0.4));
    chevron(V3KBtnLeft,  CGPointMake(cx - edge - t, cy), CGPointMake(cx - edge + t * 0.4, cy - t), CGPointMake(cx - edge + t * 0.4, cy + t));
    chevron(V3KBtnRight, CGPointMake(cx + edge + t, cy), CGPointMake(cx + edge - t * 0.4, cy - t), CGPointMake(cx + edge - t * 0.4, cy + t));
}

- (uint32_t)computeMask {
    CGRect b = self.bounds;
    CGFloat cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    CGFloat dead = MIN(b.size.width, b.size.height) * 0.14;
    uint32_t mask = 0;
    for (UITouch *t in _touches) {
        CGPoint p = [t locationInView:self];
        CGFloat dx = p.x - cx, dy = p.y - cy;
        if ((dx * dx + dy * dy) < (dead * dead)) continue;
        if (dx < -dead) mask |= V3KBtnLeft;
        if (dx >  dead) mask |= V3KBtnRight;
        if (dy < -dead) mask |= V3KBtnUp;
        if (dy >  dead) mask |= V3KBtnDown;
    }
    return mask;
}

- (void)updateFromTouches {
    uint32_t mask = [self computeMask];
    if (mask == self.directions) return;
    self.directions = mask;
    [self setNeedsDisplay];
    if (self.onDirectionsChanged) self.onDirectionsChanged(mask);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_touches unionSet:touches];
    [self updateFromTouches];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateFromTouches];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_touches minusSet:touches];
    [self updateFromTouches];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_touches minusSet:touches];
    [self updateFromTouches];
}

@end

#pragma mark - V3KThumbstickView

/// A draggable analog stick. Reports normalized offset x/y in [-1, 1]
/// (down/right positive) and snaps back to centre on release.
@interface V3KThumbstickView : UIView
@property (nonatomic, copy, nullable) NSString *caption;   // "L" / "R"
@property (nonatomic, copy, nullable) void (^onMove)(float x, float y);
@end

@implementation V3KThumbstickView {
    UITouch *_active;
    CGPoint  _knob;        // knob centre in view coords
    BOOL     _tracking;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = NO;
        _knob = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
    return self;
}

- (CGFloat)baseRadius {
    return MIN(self.bounds.size.width, self.bounds.size.height) * 0.5 - 4.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_tracking) {
        _knob = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        [self setNeedsDisplay];
    }
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat cx = CGRectGetMidX(self.bounds), cy = CGRectGetMidY(self.bounds);
    CGFloat R = [self baseRadius];

    // Base ring.
    CGRect ringRect = CGRectMake(cx - R, cy - R, R * 2.0, R * 2.0);
    [[UIColor colorWithWhite:0.10 alpha:0.45] setFill];
    CGContextFillEllipseInRect(ctx, ringRect);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetStrokeColorWithColor(ctx, [V3KGold() colorWithAlphaComponent:0.55].CGColor);
    CGContextStrokeEllipseInRect(ctx, ringRect);

    // Knob.
    CGFloat kr = R * 0.52;
    CGRect knobRect = CGRectMake(_knob.x - kr, _knob.y - kr, kr * 2.0, kr * 2.0);
    UIColor *knobFill = _tracking ? [V3KGold() colorWithAlphaComponent:0.95]
                                  : [V3KMagenta() colorWithAlphaComponent:0.80];
    [knobFill setFill];
    CGContextFillEllipseInRect(ctx, knobRect);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.9].CGColor);
    CGContextStrokeEllipseInRect(ctx, knobRect);

    if (self.caption.length) {
        UIFont *font = [UIFont systemFontOfSize:MAX(11.0, R * 0.34) weight:UIFontWeightBold];
        NSDictionary *attrs = @{ NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.9] };
        CGSize sz = [self.caption sizeWithAttributes:attrs];
        [self.caption drawAtPoint:CGPointMake(_knob.x - sz.width / 2.0, _knob.y - sz.height / 2.0)
                   withAttributes:attrs];
    }
}

- (void)moveKnobTo:(CGPoint)p {
    CGFloat cx = CGRectGetMidX(self.bounds), cy = CGRectGetMidY(self.bounds);
    CGFloat R = [self baseRadius];
    CGFloat dx = p.x - cx, dy = p.y - cy;
    CGFloat dist = hypot(dx, dy);
    if (dist > R && dist > 0.0) {
        dx = dx / dist * R;
        dy = dy / dist * R;
    }
    _knob = CGPointMake(cx + dx, cy + dy);
    [self setNeedsDisplay];
    if (self.onMove && R > 0.0) {
        self.onMove((float)(dx / R), (float)(dy / R));
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_active) return;
    _active = touches.anyObject;
    _tracking = YES;
    [self moveKnobTo:[_active locationInView:self]];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active || ![touches containsObject:_active]) return;
    [self moveKnobTo:[_active locationInView:self]];
}
- (void)endTracking {
    _active = nil;
    _tracking = NO;
    _knob = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    [self setNeedsDisplay];
    if (self.onMove) self.onMove(0.0f, 0.0f);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_active && [touches containsObject:_active]) [self endTracking];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_active && [touches containsObject:_active]) [self endTracking];
}

@end

#pragma mark - Vita3KControlsOverlay

/// Lays out the whole gamepad, keeps the pooled pressed mask, and forwards
/// button / stick / front-touch events to the core.
@interface Vita3KControlsOverlay : UIView
@property (nonatomic, copy, nullable) void (^onExit)(void);
@end

@implementation Vita3KControlsOverlay {
    V3KDPadView       *_dpad;
    V3KThumbstickView *_leftStick;
    V3KThumbstickView *_rightStick;
    UIButton          *_exitButton;
    NSArray<V3KGamepadButton *> *_buttons;   // face + shoulders + start/select
    uint32_t _buttonBits;   // discrete buttons
    uint32_t _dpadBits;     // d-pad directions
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        [self buildControls];
    }
    return self;
}

- (V3KGamepadButton *)makeFaceButton:(uint32_t)mask
                               glyph:(V3KGlyph)glyph
                              accent:(UIColor *)accent {
    V3KGamepadButton *b = [[V3KGamepadButton alloc] initWithFrame:CGRectZero];
    b.style = V3KBtnStyleFace;
    b.glyph = glyph;
    b.buttonMask = mask;
    b.accentColor = accent;
    __weak typeof(self) ws = self;
    b.onPressChanged = ^(uint32_t m, BOOL pressed) { [ws button:m pressed:pressed]; };
    [self addSubview:b];
    return b;
}

- (V3KGamepadButton *)makePillButton:(uint32_t)mask
                                text:(NSString *)text
                              accent:(UIColor *)accent {
    V3KGamepadButton *b = [[V3KGamepadButton alloc] initWithFrame:CGRectZero];
    b.style = V3KBtnStylePill;
    b.text = text;
    b.buttonMask = mask;
    b.accentColor = accent;
    __weak typeof(self) ws = self;
    b.onPressChanged = ^(uint32_t m, BOOL pressed) { [ws button:m pressed:pressed]; };
    [self addSubview:b];
    return b;
}

- (void)buildControls {
    // Face diamond: Triangle green / Circle red / Cross blue / Square magenta.
    V3KGamepadButton *tri = [self makeFaceButton:V3KBtnTriangle glyph:V3KGlyphTriangle
                                          accent:V3KGreen()];
    V3KGamepadButton *cir = [self makeFaceButton:V3KBtnCircle glyph:V3KGlyphCircle
                                          accent:[UIColor colorWithRed:0.95 green:0.30 blue:0.32 alpha:1.0]];
    V3KGamepadButton *crs = [self makeFaceButton:V3KBtnCross glyph:V3KGlyphCross
                                          accent:[UIColor colorWithRed:0.36 green:0.60 blue:1.0 alpha:1.0]];
    V3KGamepadButton *sqr = [self makeFaceButton:V3KBtnSquare glyph:V3KGlyphSquare
                                          accent:V3KMagenta()];

    // Shoulders + START/SELECT.
    V3KGamepadButton *lb = [self makePillButton:V3KBtnLTrigger text:@"L" accent:V3KGold()];
    V3KGamepadButton *rb = [self makePillButton:V3KBtnRTrigger text:@"R" accent:V3KGold()];
    V3KGamepadButton *sel = [self makePillButton:V3KBtnSelect text:@"SELECT" accent:V3KSubtext()];
    V3KGamepadButton *sta = [self makePillButton:V3KBtnStart text:@"START" accent:V3KSubtext()];

    _buttons = @[ tri, cir, crs, sqr, lb, rb, sel, sta ];

    // D-pad.
    _dpad = [[V3KDPadView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) ws = self;
    _dpad.onDirectionsChanged = ^(uint32_t mask) {
        typeof(self) ss = ws; if (!ss) return;
        ss->_dpadBits = mask;
        [ss commitButtons];
    };
    [self addSubview:_dpad];

    // Analog sticks.
    _leftStick = [[V3KThumbstickView alloc] initWithFrame:CGRectZero];
    _leftStick.caption = @"L";
    _leftStick.onMove = ^(float x, float y) { [[Vita3KCore shared] sendLeftStickX:x y:y]; };
    [self addSubview:_leftStick];

    _rightStick = [[V3KThumbstickView alloc] initWithFrame:CGRectZero];
    _rightStick.caption = @"R";
    _rightStick.onMove = ^(float x, float y) { [[Vita3KCore shared] sendRightStickX:x y:y]; };
    [self addSubview:_rightStick];

    // Exit.
    _exitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *xmark = [UIImage systemImageNamed:@"xmark.circle.fill"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
        xmark = [xmark imageByApplyingSymbolConfiguration:cfg];
    }
    [_exitButton setImage:xmark forState:UIControlStateNormal];
    _exitButton.tintColor = V3KText();
    _exitButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    _exitButton.layer.cornerRadius = 22.0;
    [_exitButton addTarget:self action:@selector(exitTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_exitButton];
}

#pragma mark Mask plumbing

- (void)button:(uint32_t)mask pressed:(BOOL)pressed {
    if (pressed) _buttonBits |= mask;
    else         _buttonBits &= ~mask;
    [self commitButtons];
}

- (void)commitButtons {
    [[Vita3KCore shared] sendButtons:(_buttonBits | _dpadBits)];
}

- (void)exitTapped {
    if (self.onExit) self.onExit();
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.safeAreaInsets;
    CGFloat left  = MAX(safe.left, 18.0);
    CGFloat right = MAX(safe.right, 18.0);
    CGFloat top   = MAX(safe.top, 14.0);
    CGFloat bottom = MAX(safe.bottom, 14.0);
    CGFloat W = b.size.width, H = b.size.height;

    // Scale factor for compact devices / portrait.
    CGFloat unit = MIN(W, H);
    CGFloat faceD = MAX(46.0, MIN(64.0, unit * 0.14));      // face-button diameter
    CGFloat dpadD = MAX(120.0, MIN(160.0, unit * 0.40));     // d-pad box
    CGFloat stickD = MAX(96.0, MIN(132.0, unit * 0.30));     // stick box

    // Shoulder buttons, top corners.
    CGFloat shoulderW = MAX(76.0, W * 0.11), shoulderH = 40.0;
    V3KGamepadButton *lb = _buttons[4], *rb = _buttons[5];
    lb.frame = CGRectMake(left, top, shoulderW, shoulderH);
    rb.frame = CGRectMake(W - right - shoulderW, top, shoulderW, shoulderH);

    // Exit button, top centre.
    CGFloat exitS = 44.0;
    _exitButton.frame = CGRectMake((W - exitS) / 2.0, top, exitS, exitS);

    // Left cluster: d-pad (upper) + left stick (lower).
    CGFloat dpadCX = left + dpadD * 0.5 + 6.0;
    CGFloat dpadCY = H * 0.44;
    _dpad.frame = CGRectMake(dpadCX - dpadD / 2.0, dpadCY - dpadD / 2.0, dpadD, dpadD);

    CGFloat lStickCX = left + stickD * 0.5 + 4.0;
    CGFloat lStickCY = H - bottom - stickD * 0.5 - 6.0;
    _leftStick.frame = CGRectMake(lStickCX - stickD / 2.0, lStickCY - stickD / 2.0, stickD, stickD);

    // Right cluster: face diamond (upper) + right stick (lower).
    CGFloat diamondR = faceD * 0.92;    // centre-to-face-centre
    CGFloat faceCX = W - right - diamondR - faceD * 0.5 - 4.0;
    CGFloat faceCY = H * 0.44;
    V3KGamepadButton *tri = _buttons[0], *cir = _buttons[1], *crs = _buttons[2], *sqr = _buttons[3];
    tri.frame = CGRectMake(faceCX - faceD / 2.0, faceCY - diamondR - faceD / 2.0, faceD, faceD); // top
    cir.frame = CGRectMake(faceCX + diamondR - faceD / 2.0, faceCY - faceD / 2.0, faceD, faceD); // right
    crs.frame = CGRectMake(faceCX - faceD / 2.0, faceCY + diamondR - faceD / 2.0, faceD, faceD); // bottom
    sqr.frame = CGRectMake(faceCX - diamondR - faceD / 2.0, faceCY - faceD / 2.0, faceD, faceD); // left

    CGFloat rStickCX = W - right - stickD * 0.5 - 4.0;
    CGFloat rStickCY = H - bottom - stickD * 0.5 - 6.0;
    _rightStick.frame = CGRectMake(rStickCX - stickD / 2.0, rStickCY - stickD / 2.0, stickD, stickD);

    // START / SELECT, small, centre-bottom.
    CGFloat ssW = MAX(78.0, W * 0.10), ssH = 34.0, ssGap = 16.0;
    CGFloat ssY = H - bottom - ssH;
    V3KGamepadButton *sel = _buttons[6], *sta = _buttons[7];
    sel.frame = CGRectMake(W / 2.0 - ssW - ssGap / 2.0, ssY, ssW, ssH);
    sta.frame = CGRectMake(W / 2.0 + ssGap / 2.0, ssY, ssW, ssH);
}

#pragma mark Front-panel touch pass-through

// Only capture touches that land on an actual control; let the rest fall
// through to the overlay itself, which forwards them as front touchscreen input.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return self;   // empty area -> front touch (handled below)
    return hit;
}

- (void)forwardFront:(NSSet<UITouch *> *)touches down:(BOOL)down {
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    CGFloat nx = self.bounds.size.width  > 0 ? p.x / self.bounds.size.width  : 0.0;
    CGFloat ny = self.bounds.size.height > 0 ? p.y / self.bounds.size.height : 0.0;
    nx = MAX(0.0, MIN(1.0, nx));
    ny = MAX(0.0, MIN(1.0, ny));
    [[Vita3KCore shared] sendTouchFront:CGPointMake(nx, ny) down:down];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self forwardFront:touches down:YES];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self forwardFront:touches down:YES];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self forwardFront:touches down:NO];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self forwardFront:touches down:NO];
}

@end

#pragma mark - EmulatorViewController

@interface EmulatorViewController ()
@property (nonatomic, copy) NSString *titleId;
@property (nonatomic, strong) V3KMetalSurfaceView *surface;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) Vita3KControlsOverlay *controls;
@property (nonatomic, assign) BOOL didBoot;
@end

@implementation EmulatorViewController

- (instancetype)initWithTitleId:(NSString *)titleId {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _titleId = [titleId copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // Metal game surface, full screen behind everything.
    self.surface = [[V3KMetalSurfaceView alloc] initWithFrame:self.view.bounds];
    self.surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.surface];

    // "core not linked" preview label, centred over the surface.
    if (![[Vita3KCore shared] coreLinked]) {
        self.previewLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.previewLabel.numberOfLines = 0;
        self.previewLabel.textAlignment = NSTextAlignmentCenter;
        self.previewLabel.textColor = V3KSubtext();
        self.previewLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
        self.previewLabel.text = @"Vita3K core not linked yet\n(front-end preview)";
        [self.view addSubview:self.previewLabel];
    }

    // Controls overlay on top.
    self.controls = [[Vita3KControlsOverlay alloc] initWithFrame:self.view.bounds];
    self.controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.controls.alpha = [self controlsOpacity];
    __weak typeof(self) ws = self;
    self.controls.onExit = ^{ [ws exitEmulator]; };
    [self.view addSubview:self.controls];
}

- (CGFloat)controlsOpacity {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:@"v3k.controlsOpacity"];
    CGFloat opacity = v ? (CGFloat)[d floatForKey:@"v3k.controlsOpacity"] : 0.85;
    if (opacity < 0.20) opacity = 0.20;    // never fully invisible / unusable
    if (opacity > 1.0)  opacity = 1.0;
    return opacity;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.surface.frame = self.view.bounds;
    self.controls.frame = self.view.bounds;
    if (self.previewLabel) {
        CGFloat w = MIN(self.view.bounds.size.width - 48.0, 420.0);
        [self.previewLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
        self.previewLabel.frame = CGRectMake((self.view.bounds.size.width - w) / 2.0,
                                             self.view.bounds.size.height / 2.0 - 40.0,
                                             w, 80.0);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didBoot) return;

    Vita3KCore *core = Vita3KCore.shared;
    // No executable arena means the recompiler would fault on the guest's first
    // instruction. Say so plainly instead of showing a black screen.
    if (core.coreLinked && !core.jitArenaReady) {
        [core prepareJITWithCompletion:^(BOOL ok, NSError *error) {
            if (ok) {
                self.didBoot = YES;
                [core bootTitleId:self.titleId inLayer:self.surface.layer];
                return;
            }
            NSString *msg = error.localizedDescription.length
                ? error.localizedDescription
                : @"JIT memory is not available, so the recompiler cannot run.";
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"JIT Not Ready"
                                 message:[msg stringByAppendingString:
                    @"\n\nOpen StikDebug, enable JIT for Vita3K with universal.js attached, "
                     "then launch the game again."]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Enable JIT" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *_){ [core requestJITViaStikDebug]; }]];
            [a addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel
                handler:^(UIAlertAction *_){ [self exitEmulator]; }]];
            [self presentViewController:a animated:YES completion:nil];
        }];
        return;
    }

    self.didBoot = YES;
    [core bootTitleId:self.titleId inLayer:self.surface.layer];
}

- (void)exitEmulator {
    [[Vita3KCore shared] shutdown];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Chrome

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight;
}

@end
