// A touch-owned left stick sends WASD or feeds the GameController API the client uses for physical pads.
// Included on iPhone and iPad only. A separate handle moves the control, never the character.
static NSString *const sp_joystick_enabled_key = @"sp_joystick_enabled";
static NSString *const sp_joystick_position_key = @"sp_joystick_position";
static NSString *const sp_joystick_size_key = @"sp_joystick_size";
static const CGFloat sp_joystick_default_size = 156, sp_joystick_min_size = 100, sp_joystick_max_size = 260;
// About one centimeter on a full-size iPad. Fixed points keep the shield independent of stick size.
static const CGFloat sp_joystick_touch_margin = 52;
static const NSTimeInterval sp_joystick_move_hold = 2;

static NSArray<NSString *> *sp_gamepad_buttons(void) {
    return @[GCInputButtonA, GCInputLeftShoulder, GCInputRightShoulder, GCInputButtonX];
}

static CGPoint sp_stick_value(CGPoint offset, CGFloat travel, CGFloat deadzone) {
    CGFloat x = offset.x / travel, y = -offset.y / travel;
    CGFloat length = hypot(x, y);
    if (length <= deadzone) return CGPointZero;
    CGFloat strength = MIN(1, (length - deadzone) / (1 - deadzone));
    return CGPointMake(x / length * strength, y / length * strength);
}

@protocol SPMovableControl <NSObject>
- (void)beginMove:(UITouch *)touch;
- (void)moveWithTouch:(UITouch *)touch;
- (void)endMove;
@end

@interface SPJoystick : UIControl <SPMovableControl>
@property(nonatomic) BOOL compactHUD;
@property(nonatomic) BOOL showsMoveHandle;
@property(nonatomic, readonly) CGPoint value;
@property(nonatomic, readonly) GCController *controller;
@property(nonatomic, readonly) BOOL gamepadReady;
- (BOOL)setGamepadButton:(NSString *)element pressed:(BOOL)pressed;
- (void)setCameraAxis:(CGPoint)value;
- (void)layoutInRect:(CGRect)rect;
@property(nonatomic, copy) void (^autorunChanged)(BOOL);
- (void)toggleAutorun;
- (void)stopAutorun;
- (void)cancelInput;
- (void)setSuspended:(BOOL)suspended;
- (void)gameDidStart;
- (void)updateTouch:(UITouch *)touch;
- (BOOL)containsStickPoint:(CGPoint)point;
- (void)beginMove:(UITouch *)touch;
- (void)moveWithTouch:(UITouch *)touch;
- (void)endMove;
@end

// A touch that begins in the margin belongs here until it lifts, even if it drifts onto the game or
// into the stick. Never forward it up the responder chain, and never turn it into movement.
@interface SPJoystickShield : UIView
@property(nonatomic, weak) SPJoystick *joystick;
@end
@implementation SPJoystickShield
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint p = [self.joystick convertPoint:point fromView:self];
    return [self.joystick pointInside:p withEvent:event] && ![self.joystick containsStickPoint:p];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

@interface SPJoystickHandle : UIControl
@property(nonatomic, weak) UIView<SPMovableControl> *joystick;
@property(nonatomic) BOOL ring;
- (void)cancelTouch;
@end

@implementation SPJoystickHandle {
    UITouch *_touch;
    CGPoint _pressStart;
    NSUInteger _holdGeneration;
    UILabel *_grip;
    CAShapeLayer *_progress;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.exclusiveTouch = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = @"Move left joystick";
    self.accessibilityHint = @"Hold for two seconds, then drag to save a new joystick position.";
    self.accessibilityIdentifier = @"sp.left-joystick-move";
    UIColor *gold = [UIColor colorWithRed:0.78 green:0.73 blue:0.59 alpha:1];
    _progress = [NSClassFromString(@"CAShapeLayer") layer];  // QuartzCore isn't linked, as spwindow.m
    _progress.frame = self.bounds;
    _progress.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 40, 40) cornerRadius:10].CGPath;
    _progress.fillColor = UIColor.clearColor.CGColor;
    _progress.strokeColor = gold.CGColor;
    _progress.lineWidth = 2;
    _progress.strokeEnd = 0;
    [self.layer addSublayer:_progress];
    _grip = [[UILabel alloc] initWithFrame:CGRectMake(8, 8, 28, 28)];
    _grip.userInteractionEnabled = NO;
    _grip.text = @"↔";
    _grip.font = [UIFont systemFontOfSize:21 weight:UIFontWeightSemibold];
    _grip.textAlignment = NSTextAlignmentCenter;
    _grip.layer.cornerRadius = 7;
    _grip.clipsToBounds = YES;
    [self addSubview:_grip];
    [self setHighlighted:NO];
    return self;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    UIColor *gold = [UIColor colorWithRed:0.78 green:0.73 blue:0.59 alpha:1];
    _grip.textColor = highlighted ? [UIColor colorWithWhite:0.06 alpha:1] : gold;
    _grip.backgroundColor = highlighted ? gold : [UIColor colorWithWhite:0.1 alpha:0.95];
    if (self.ring) self.layer.borderColor = [gold colorWithAlphaComponent:highlighted ? 1 : 0.45].CGColor;
    self.accessibilityValue = highlighted ? @"Unlocked for dragging" : @"Hold for two seconds";
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _progress.frame = self.bounds;
    _grip.hidden = self.ring;
    if (self.ring) {
        self.layer.cornerRadius = self.bounds.size.width / 2;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithRed:0.78 green:0.73 blue:0.59 alpha:self.highlighted ? 1 : 0.45].CGColor;
        _progress.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, 3, 3)].CGPath;
    }
}
- (void)cancelTouch {
    _touch = nil;
    _holdGeneration++;
    [_progress removeAllAnimations];
    Class tx = NSClassFromString(@"CATransaction");
    [tx begin]; [tx setDisableActions:YES];
    _progress.strokeEnd = 0;
    [tx commit];
    [self setHighlighted:NO];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch) return;
    for (UITouch *touch in touches) if (touch.type == UITouchTypeDirect || (self.ring && touch.type == UITouchTypePencil)) {
        _touch = touch;
        _pressStart = [touch locationInView:self.joystick.superview];
        NSUInteger generation = ++_holdGeneration;
        CABasicAnimation *countdown = [NSClassFromString(@"CABasicAnimation") animationWithKeyPath:@"strokeEnd"];
        countdown.fromValue = @0; countdown.toValue = @1;
        countdown.duration = sp_joystick_move_hold;
        Class tx = NSClassFromString(@"CATransaction");
        [tx begin]; [tx setDisableActions:YES];
        _progress.strokeEnd = 1;
        [tx commit];
        [_progress addAnimation:countdown forKey:@"sp.move-hold"];
        __weak SPJoystickHandle *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sp_joystick_move_hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPJoystickHandle *self = weakSelf;
            // A quick press, early drag, resize, or app switch invalidates the pending unlock.
            if (!self || self->_holdGeneration != generation || self->_touch != touch ||
                touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) return;
            [self setHighlighted:YES];
            [self.joystick beginMove:touch];
        });
        break;
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_touch || ![touches containsObject:_touch]) return;
    if (self.highlighted) { [self.joystick moveWithTouch:_touch]; return; }
    CGPoint at = [_touch locationInView:self.joystick.superview];
    // A small resting-thumb drift is fine; an early drag is an accidental grab, not a deferred jump.
    if (hypot(at.x - _pressStart.x, at.y - _pressStart.y) > 12) [self cancelTouch];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) {
        if (self.highlighted) { [self.joystick moveWithTouch:_touch]; [self.joystick endMove]; }
        [self cancelTouch];
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) { [self.joystick endMove]; [self cancelTouch]; }
}
@end

@implementation SPJoystick {
    UIView *_knob;
    UILabel *_status;
    SPJoystickHandle *_handle;
    SPJoystickShield *_shield;
    UITouch *_stickTouch;
    GCVirtualController *_virtualController;
    CGPoint _value, _position, _fingerStart, _centerStart, _stickOrigin;
    CGRect _centers;
    BOOL _moving, _suspended, _connected, _gameReady, _requested, _analog, _analogFallback, _fullGamepad;
    unsigned _movementKeys;
    BOOL _autorun;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hidden = YES;
    _showsMoveHandle = YES;
    _gameReady = atomic_load(&sp_game_presented);
    self.exclusiveTouch = NO;
    self.multipleTouchEnabled = NO;
    self.layer.zPosition = 1200;
    self.layer.borderWidth = 1.5;
    UIColor *gold = [UIColor colorWithRed:0.78 green:0.73 blue:0.59 alpha:1];
    self.layer.borderColor = [gold colorWithAlphaComponent:0.6].CGColor;
    self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.45];
    self.isAccessibilityElement = NO;  // keep the move handle independently discoverable
    self.accessibilityIdentifier = @"sp.left-joystick";
    _shield = [SPJoystickShield new];
    _shield.joystick = self;
    _shield.multipleTouchEnabled = YES;
    _shield.isAccessibilityElement = NO;
    _shield.accessibilityIdentifier = @"sp.left-joystick-shield";
    [self addSubview:_shield];
    _knob = [UIView new];
    _knob.userInteractionEnabled = NO;
    _knob.backgroundColor = [gold colorWithAlphaComponent:0.65];
    [self addSubview:_knob];
    _status = [UILabel new];
    _status.userInteractionEnabled = NO;
    _status.textColor = gold;
    _status.textAlignment = NSTextAlignmentCenter;
    _status.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    [_knob addSubview:_status];
    _handle = [[SPJoystickHandle alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    _handle.joystick = self;
    [self addSubview:_handle];
    return self;
}

- (CGPoint)value { return _value; }
- (GCController *)controller { return _connected ? _virtualController.controller : nil; }
- (BOOL)gamepadReady { return _fullGamepad && _connected; }

- (BOOL)setGamepadButton:(NSString *)element pressed:(BOOL)pressed {
    if (!self.gamepadReady) return NO;
    [_virtualController setValue:pressed ? 1 : 0 forButtonElement:element];
    return YES;
}

- (void)setCameraAxis:(CGPoint)value {
    if (self.gamepadReady) [_virtualController setPosition:value forDirectionPadElement:GCInputRightThumbstick];
}

- (void)disconnectController {
    if (_fullGamepad && _connected) {
        [self setCameraAxis:CGPointZero];
        for (NSString *element in sp_gamepad_buttons()) [self setGamepadButton:element pressed:NO];
    }
    [_virtualController disconnect];
    _virtualController = nil;
    _connected = NO;
}

- (void)drawValue {
    CGFloat size = self.bounds.size.width, travel = size * 0.30, knobSize = size * 0.36;
    _knob.bounds = CGRectMake(0, 0, knobSize, knobSize);
    _knob.layer.cornerRadius = knobSize / 2;
    CGPoint center = _stickTouch ? _stickOrigin : CGPointMake(size / 2, size / 2);
    CGPoint thumb = CGPointMake(center.x + _value.x * travel, center.y - _value.y * travel);
    CGFloat dx = thumb.x - size / 2, dy = thumb.y - size / 2;
    CGFloat maxDistance = (size - knobSize) / 2;
    CGFloat distance = hypot(dx, dy);
    CGFloat inset = distance > maxDistance ? maxDistance / distance : 1;
    _knob.center = CGPointMake(size / 2 + dx * inset, size / 2 + dy * inset);
    _status.frame = _knob.bounds;
}

- (void)sendValue:(CGPoint)value {
    _value = value;
    if (_connected) [_virtualController setPosition:value forDirectionPadElement:GCInputLeftThumbstick];
    // Per-axis thresholds preserve diagonals, with hysteresis near each direction's boundary.
    const CGFloat axes[] = {value.y, -value.x, -value.y, value.x};
    const unsigned usages[] = {0x1A, 0x04, 0x16, 0x07}; // W, A, S, D
    for (unsigned i = 0; i < 4; i++) {
        unsigned bit = 1 << i;
        BOOL held = (_movementKeys & bit) != 0;
        BOOL next = (!_analog || _analogFallback) && ((i == 0 && _autorun) || axes[i] >= (held ? 0.18 : 0.27));
        if (held == next) continue;
        _movementKeys ^= bit;
        sp_touch_key(usages[i], next);
    }
    [self drawValue];
}

- (void)setAutorunActive:(BOOL)active {
    if (_autorun == active) return;
    _autorun = active;
    _status.text = active ? @"⇈" : nil;
    [self sendValue:_value];
    if (self.autorunChanged) self.autorunChanged(active);
}

- (void)toggleAutorun {
    if (!_analog && !_suspended && !self.hidden && !_stickTouch) [self setAutorunActive:!_autorun];
}

- (void)stopAutorun { [self setAutorunActive:NO]; }

- (void)cancelInput {
    if (_autorun) {
        _autorun = NO;
        _status.text = nil;
        if (self.autorunChanged) self.autorunChanged(NO);
    }
    _stickTouch = nil;
    [self sendValue:CGPointZero];
    [self endMove];
    [_handle cancelTouch];
}

- (void)updateConnection {
    if (!_analog) return;
    BOOL want = _gameReady && _requested && self.window && !self.hidden && !_suspended &&
                self.window.windowScene.activationState == UISceneActivationStateForegroundActive;
    if (!want) {
        [self cancelInput];
        BOOL wasConnected = _connected;
        [self disconnectController];
        _analogFallback = NO;
        _status.text = nil;
        if (wasConnected) [self.superview setNeedsLayout];
        return;
    }
    if (_virtualController) return;  // includes an asynchronous connect already in progress
    GCVirtualControllerConfiguration *config = [GCVirtualControllerConfiguration new];
    NSMutableSet<NSString *> *elements = [NSMutableSet setWithObject:GCInputLeftThumbstick];
    if (_fullGamepad) {
        [elements addObject:GCInputRightThumbstick];
        [elements addObjectsFromArray:sp_gamepad_buttons()];
    }
    config.elements = elements;
    config.hidden = YES;  // our own view supplies the axes, with no system-wide touch overlay
    GCVirtualController *virtualController = [[GCVirtualController alloc] initWithConfiguration:config];
    _virtualController = virtualController;
    sp_stub_log("input: virtual left joystick connecting");
    __weak SPJoystick *weakSelf = self;
    [virtualController connectWithReplyHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPJoystick *self = weakSelf;
            // Disabling or backgrounding during connect must not leave a phantom controller behind.
            if (!self || self->_virtualController != virtualController) { [virtualController disconnect]; return; }
            self->_connected = !error && virtualController.controller != nil;
            self->_status.text = self->_connected ? nil : @"!";
            if (!self->_connected) {
                sp_stub_log("input: virtual controller connection failed; using WASD until retry");
                [self disconnectController];
                self->_analogFallback = YES;
                [self sendValue:self->_value];
                return;
            }
            self->_analogFallback = NO;
            [self.superview setNeedsLayout];
            sp_stub_log(self->_fullGamepad ? "input: experimental virtual gamepad connected"
                                           : "input: virtual left joystick connected");
            // The first touch deliberately starts connection after the game is in use. Preserve
            // that held touch, but never revive one lifted/cancelled while the connection was pending.
            UITouch *touch = self->_stickTouch;
            if (touch && touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled)
                [self updateTouch:touch];
            else {
                self->_stickTouch = nil;
                [self sendValue:CGPointZero];
            }
        });
    }];
}

- (void)setSuspended:(BOOL)suspended {
    _suspended = suspended;
    if (suspended) [self cancelInput];
    [self updateConnection];
}

- (void)gameDidStart {
    if (_gameReady) return;
    _gameReady = YES;
    sp_stub_log("input: virtual left joystick game ready");
    [self updateConnection];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self cancelInput];
    [self updateConnection];
}

- (void)dealloc {
    [_virtualController disconnect];
}

- (void)layoutInRect:(CGRect)rect {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL analog = [defaults boolForKey:@"sp_joystick_analog"];
    BOOL fullGamepad = analog && self.compactHUD && [defaults boolForKey:@"sp_touch_virtual_gamepad"];
    if (_analog != analog || _fullGamepad != fullGamepad) {
        [self cancelInput];
        [self disconnectController];
        _requested = _analogFallback = NO;
        _status.text = nil;
        _analog = analog;
        _fullGamepad = fullGamepad;
    }
    BOOL enabled = ![defaults objectForKey:sp_joystick_enabled_key] || [defaults boolForKey:sp_joystick_enabled_key];
    CGFloat size = self.compactHUD
        ? sp_touch_number(sp_joystick_size_key, sp_joystick_default_size, sp_joystick_min_size, sp_joystick_max_size)
            * 108 / sp_joystick_default_size
        : sp_touch_number(sp_joystick_size_key, sp_joystick_default_size, sp_joystick_min_size, sp_joystick_max_size);
    size *= sp_touch_setting(@"sp_touch_controls_scale", 0.6, 1.6);
    CGFloat minimum = self.compactHUD ? 68 : sp_joystick_min_size;
    BOOL room = !CGRectIsNull(rect) && MIN(rect.size.width, rect.size.height) >= minimum + 16;
    if (room) size = MIN(size, MIN(rect.size.width, rect.size.height) - 16);
    CGRect centers = room ? CGRectInset(rect, size / 2 + 8, size / 2 + 8) : CGRectZero;
    if (!enabled || !room || !CGRectEqualToRect(centers, _centers)) [self cancelInput];
    self.hidden = !enabled || !room;
    if (!self.hidden) {
        _centers = centers;
        if (!_moving) {
            _position = CGPointMake(self.compactHUD ? 0.18 : 0.12, 1);
            id saved = [defaults objectForKey:sp_joystick_position_key];
            if ([saved isKindOfClass:NSArray.class] && [saved count] == 2 &&
                [saved[0] isKindOfClass:NSNumber.class] && [saved[1] isKindOfClass:NSNumber.class]) {
                double x = [saved[0] doubleValue], y = [saved[1] doubleValue];
                if (isfinite(x) && isfinite(y)) _position = CGPointMake(MAX(0, MIN(1, x)), MAX(0, MIN(1, y)));
            }
        }
        self.bounds = CGRectMake(0, 0, size, size);
        self.layer.cornerRadius = size / 2;
        self.center = CGPointMake(centers.origin.x + centers.size.width * sp_touch_x(_position.x),
                                 centers.origin.y + centers.size.height * _position.y);
        UIColor *ink = self.compactHUD ? sp_hud_ink() : [UIColor colorWithRed:0.78 green:0.73 blue:0.59 alpha:1];
        self.layer.borderWidth = self.compactHUD ? 1 : 1.5;
        self.layer.borderColor = [ink colorWithAlphaComponent:0.66].CGColor;
        self.backgroundColor = self.compactHUD ? [sp_hud_surface() colorWithAlphaComponent:0.55]
                                              : [UIColor colorWithWhite:0.06 alpha:0.45];
        _knob.backgroundColor = [ink colorWithAlphaComponent:self.compactHUD ? 0.32 : 0.65];
        _status.textColor = ink;
        _status.font = [UIFont systemFontOfSize:self.compactHUD ? 15 : 24 weight:UIFontWeightSemibold];
        CGFloat handleSize = MIN(size / 2, 44 * sp_touch_setting(@"sp_touch_controls_scale", 0.6, 1.6));
        if (!self.showsMoveHandle && !_handle.hidden) {
            [_handle cancelTouch];
            [self endMove];
        }
        _handle.hidden = !self.showsMoveHandle;
        _handle.frame = CGRectMake(size - handleSize, 0, handleSize, handleSize);
        CGFloat margin = self.compactHUD ? 0 : sp_joystick_touch_margin;
        _shield.frame = CGRectInset(self.bounds, -margin, -margin);
        [self drawValue];
    }
    [self updateConnection];
}

- (BOOL)containsStickPoint:(CGPoint)point {
    CGFloat r = self.bounds.size.width / 2;
    return CGRectContainsPoint(self.bounds, point) &&
           (hypot(point.x - r, point.y - r) <= r || (!_handle.hidden && CGRectContainsPoint(_handle.frame, point)));
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if ([self containsStickPoint:point]) return YES;
    if (self.compactHUD) return NO;  // HUD 5's joystick keeps the surrounding chat and game area tappable.
    // Extend UIKit hit testing outside the visible circle without blocking a hardware pointer's clicks
    // or hover there. allTouches can still be empty during UIKit's initial hit test.
    if (event && event.type != UIEventTypeTouches) return NO;
    for (UITouch *touch in event.allTouches) {
        CGPoint p = [touch locationInView:self];
        if (touch.phase == UITouchPhaseBegan && hypot(p.x - point.x, p.y - point.y) < 0.5 &&
            touch.type != UITouchTypeDirect) return NO;
    }
    CGFloat r = self.bounds.size.width / 2;
    return hypot(point.x - r, point.y - r) <= r + sp_joystick_touch_margin;
}

- (void)updateTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    CGPoint offset = CGPointMake(p.x - _stickOrigin.x, p.y - _stickOrigin.y);
    CGFloat deadzone = sp_touch_number(@"sp_joystick_deadzone", 0.12, 0, 0.5);
    [self sendValue:sp_stick_value(offset, self.bounds.size.width * 0.30, deadzone)];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // The SP_HOVER_OFF development override removes first-frame hooks. A first stick touch is a
    // fallback in that mode. In normal launches a frame permits connection, but the first stick use
    // requests it: the login/menu's first present can precede the game's controller initialization.
    if (!_gameReady && (atomic_load(&sp_game_presented) || getenv("SP_HOVER_OFF"))) [self gameDidStart];
    static int logged;
    if (logged++ < 4)
        sp_stub_log([NSString stringWithFormat:@"input: joystick touch ready=%d suspended=%d moving=%d hidden=%d window=%d scene=%ld",
                     _gameReady, _suspended, _moving, self.hidden, self.window != nil,
                     (long)self.window.windowScene.activationState].UTF8String);
    if (_stickTouch || _moving || self.hidden) return;
    for (UITouch *touch in touches) if (touch.type == UITouchTypeDirect && !sp_physical_touch(touch)) {
        if (![self containsStickPoint:[touch locationInView:self]]) continue;
        // A real new touch in an active scene is fresher than a missed activation notification.
        // Keep background cancellation intact: old moved touches never enter this recovery path.
        if (_suspended && self.window && self.window.windowScene &&
            self.window.windowScene.activationState == UISceneActivationStateForegroundActive) {
            _suspended = NO;
            sp_stub_log("input: virtual left joystick recovered foreground touch");
        }
        if (_suspended) return;
        [self stopAutorun];
        _stickOrigin = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"sp_joystick_floating"])
            _stickOrigin = [touch locationInView:self];
        _stickTouch = touch;
        if (_analog && !_gameReady) _analogFallback = YES;
        _requested = YES;
        [self updateConnection];
        if (_stickTouch == touch) [self updateTouch:touch];
        break;
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_stickTouch && [touches containsObject:_stickTouch]) [self updateTouch:_stickTouch];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_stickTouch && [touches containsObject:_stickTouch]) [self cancelInput];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_stickTouch && [touches containsObject:_stickTouch]) [self cancelInput];
}

- (void)beginMove:(UITouch *)touch {
    _stickTouch = nil;
    [self stopAutorun];
    [self sendValue:CGPointZero];
    [self endMove];
    _moving = YES;
    _fingerStart = [touch locationInView:self.superview];
    _centerStart = self.center;
}
- (void)moveWithTouch:(UITouch *)touch {
    if (!_moving) return;
    CGPoint p = [touch locationInView:self.superview];
    self.center = CGPointMake(MAX(CGRectGetMinX(_centers), MIN(CGRectGetMaxX(_centers), _centerStart.x + p.x - _fingerStart.x)),
                              MAX(CGRectGetMinY(_centers), MIN(CGRectGetMaxY(_centers), _centerStart.y + p.y - _fingerStart.y)));
    _position = CGPointMake(sp_touch_x(_centers.size.width ? (self.center.x - _centers.origin.x) / _centers.size.width : 0.5),
                            _centers.size.height ? (self.center.y - _centers.origin.y) / _centers.size.height : 0);
}
- (void)endMove {
    if (!_moving) return;
    _moving = NO;
    [NSUserDefaults.standardUserDefaults setObject:@[@(_position.x), @(_position.y)] forKey:sp_joystick_position_key];
}
@end

@interface SPGamepadCamera : UIControl
@property(nonatomic, weak) SPJoystick *joystick;
- (void)cancelInput;
@end

@implementation SPGamepadCamera {
    UITouch *_touch;
    CGPoint _origin;
}

- (void)cancelInput {
    if (!_touch) return;
    _touch = nil;
    [self.joystick setCameraAxis:CGPointZero];
    self.highlighted = NO;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat radius = self.bounds.size.width / 2;
    return hypot(point.x - radius, point.y - radius) <= radius;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch || !self.joystick.gamepadReady) return;
    for (UITouch *touch in touches) {
        if (touch.type != UITouchTypeDirect || sp_physical_touch(touch)) continue;
        _touch = touch;
        _origin = [touch locationInView:self];
        self.highlighted = YES;
        break;
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_touch || ![touches containsObject:_touch]) return;
    CGPoint point = [_touch locationInView:self];
    CGPoint offset = CGPointMake(point.x - _origin.x, point.y - _origin.y);
    CGFloat travel = 24 / sp_touch_setting(@"sp_touch_camera_sensitivity", 0.25, 3);
    [self.joystick setCameraAxis:sp_stick_value(offset, travel, 0.12)];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) [self cancelInput];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
@end
