// Optional touch-owned keyboard keys. Modifier squares drag like R. The whole Space circle presses
// its key and starts the joystick's timed unlock; after two seconds, release Space and allow moving.
static NSString *const sp_keyboard_size_key = @"sp_keyboard_size";
static NSString *sp_space_last_release;
static const CGFloat sp_keyboard_default_size = 76, sp_keyboard_min_size = 44, sp_keyboard_max_size = 152;

@interface SPKeyboardButton : UIControl <SPMovableControl>
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, copy) void (^action)(void);
@property(nonatomic) NSInteger compactColumn; // One-based, mirrored from the outside of each digit row.
@property(nonatomic) BOOL editingPosition;
- (instancetype)initWithName:(NSString *)name label:(NSString *)label usage:(unsigned)usage position:(CGPoint)position;
- (void)layoutInRect:(CGRect)rect;
- (void)cancelInputWithReason:(NSString *)reason;
- (void)setActionActive:(BOOL)active;
- (void)syncWithEvent:(UIEvent *)event;
- (BOOL)containsKeyPoint:(CGPoint)point;
@end

// As with the joystick, a contact starting in the invisible margin stays inert until it lifts.
@interface SPKeyboardShield : UIView
@property(nonatomic, weak) SPKeyboardButton *button;
@end
@implementation SPKeyboardShield
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint p = [self.button convertPoint:point fromView:self];
    return [self.button pointInside:p withEvent:event] && ![self.button containsKeyPoint:p];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

@implementation SPKeyboardButton {
    NSString *_name, *_enabledKey, *_positionKey;
    unsigned _usage;
    BOOL _actionActive, _layoutDeferred;
    UIView *_face;
    UILabel *_label;
    SPJoystickHandle *_handle;
    SPKeyboardShield *_shield;
    UITouch *_touch;
    CGPoint _position, _defaultPosition, _fingerStart, _centerStart;
    CGRect _centers;
    BOOL _moving, _keyDown, _latched;
}
- (instancetype)initWithName:(NSString *)name label:(NSString *)label usage:(unsigned)usage position:(CGPoint)position {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _name = name; _usage = usage; _position = _defaultPosition = position;
    _enabledKey = [NSString stringWithFormat:@"sp_%@_enabled", name];
    _positionKey = [NSString stringWithFormat:@"sp_%@_position", name];
    self.hidden = YES;
    self.exclusiveTouch = NO;
    self.multipleTouchEnabled = NO;
    self.layer.zPosition = 1200;
    self.accessibilityIdentifier = [@"sp.key-" stringByAppendingString:name];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = label;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityHint = @"Hold to press this key. Drag to save a new position.";
    _face = [UIView new]; _face.userInteractionEnabled = NO;
    _face.layer.cornerRadius = 8; _face.layer.borderWidth = 1.5;
    [self addSubview:_face];
    _label = [UILabel new]; _label.text = label; _label.textAlignment = NSTextAlignmentCenter;
    _label.adjustsFontSizeToFitWidth = YES; _label.minimumScaleFactor = 0.5;
    [_face addSubview:_label];
    if (usage == 0x2C) {
        self.accessibilityLabel = @"Spacebar";
        self.accessibilityHint = @"Press anywhere in the circle to hold Space. Hold still for two seconds until the ring fills, then drag to move.";
        _shield = [SPKeyboardShield new]; _shield.button = self;
        _shield.multipleTouchEnabled = YES;
        _shield.accessibilityIdentifier = @"sp.key-space-shield";
        [self insertSubview:_shield atIndex:0];
        _handle = [[SPJoystickHandle alloc] initWithFrame:CGRectZero];
        _handle.joystick = self; _handle.ring = YES;
        // The ring only draws feedback. Forward the circle's touch into its existing hold state machine.
        _handle.userInteractionEnabled = NO;
        _handle.isAccessibilityElement = NO;
        _handle.accessibilityIdentifier = @"sp.key-space-move";
        [self addSubview:_handle];
    }
    [self setHighlighted:NO];
    return self;
}
- (NSString *)name { return _name; }
- (void)setHighlighted:(BOOL)highlighted {
    highlighted = highlighted || _actionActive;
    [super setHighlighted:highlighted];
    UIColor *gold = [UIColor colorWithRed:0.78 green:0.73 blue:0.59 alpha:1];
    _face.backgroundColor = highlighted ? gold : [UIColor colorWithWhite:0.06 alpha:0.8];
    _face.layer.borderColor = [gold colorWithAlphaComponent:highlighted ? 1 : 0.7].CGColor;
    _label.textColor = highlighted ? [UIColor colorWithWhite:0.06 alpha:1] : gold;
    self.accessibilityValue = _face.accessibilityValue = highlighted ? @"Held" : @"Released";
}
- (void)setActionActive:(BOOL)active {
    _actionActive = active;
    [self setHighlighted:NO];
}
- (void)setEditingPosition:(BOOL)editingPosition {
    if (_editingPosition == editingPosition) return;
    [self cancelInputWithReason:@"edit mode changed"];
    _editingPosition = editingPosition;
}
- (void)releaseKeyWithReason:(NSString *)reason {
    _latched = NO;
    if (_keyDown) {
        if (_usage == 0x2C) sp_space_last_release = reason;
        sp_touch_key(_usage, NO);
    }
    _keyDown = NO;
    [self setHighlighted:NO];
}
- (void)flushDeferredLayout {
    if (!_layoutDeferred) return;
    _layoutDeferred = NO;
    [self.superview setNeedsLayout];
}
- (void)cancelInputWithReason:(NSString *)reason {
    [self releaseKeyWithReason:reason];
    _touch = nil;
    [self endMove];
    [_handle cancelTouch];
    [self flushDeferredLayout];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self cancelInputWithReason:@"detached from window"];
}
- (void)layoutInRect:(CGRect)rect {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id savedSize = [defaults objectForKey:sp_keyboard_size_key];
    double size = [savedSize isKindOfClass:NSNumber.class] ? [savedSize doubleValue] : sp_keyboard_default_size;
    if (!isfinite(size)) size = sp_keyboard_default_size;
    size = MAX(sp_keyboard_min_size, MIN(sp_keyboard_max_size, size));
    CGFloat scale = sp_touch_setting(@"sp_touch_controls_scale", 0.6, 1.6);
    CGFloat ring = _handle ? 52 * scale : 0;
    CGFloat outer = size * scale + ring;
    CGFloat minimum = sp_keyboard_min_size * scale + ring;
    if (_compactColumn) {
        // Reserve a gap between the two groups even at maximum scale in landscape.
        CGFloat cell = MAX(0, (CGRectGetWidth(rect) - 92) / 10);
        outer = MIN(size * 0.60 * scale, cell - 4);
        minimum = 18;
    } else if (_action || _usage == 0x2B) {
        outer = size * 0.64 * scale;
        minimum = 24;
    }
    BOOL room = !CGRectIsNull(rect) && outer >= minimum && rect.size.width >= minimum + 16 && rect.size.height >= minimum + 16;
    if (room) outer = MIN(outer, MIN(rect.size.width, rect.size.height) - 16);
    CGRect lane = rect;
    if (room && _compactColumn) {
        lane.size.width = (CGRectGetWidth(rect) - 76) / 2;
        if (sp_touch_x(_defaultPosition.x) == 1) lane.origin.x = CGRectGetMaxX(rect) - lane.size.width;
    }
    CGRect centers = room ? CGRectInset(lane, outer / 2 + 8, outer / 2 + 8) : CGRectZero;
    BOOL enabled = [defaults objectForKey:_enabledKey] ? [defaults boolForKey:_enabledKey]
                                                       : !(_usage >= 0xE0 && _usage <= 0xE2);
    BOOL geometryChanged = !CGRectEqualToRect(centers, _centers) ||
                           (room && outer != CGRectGetWidth(self.bounds));
    if (enabled && room && geometryChanged && _handle && _touch && !_moving) {
        // Keep Jump under the owning finger until lift. The resize invalidates the move ring's
        // gesture, but Space stays down and the latest layout is applied once the touch ends.
        if (!_layoutDeferred) [_handle cancelTouch];
        _layoutDeferred = YES;
        return;
    }
    if (!enabled || !room || geometryChanged)
        [self cancelInputWithReason:!enabled ? @"disabled" : !room ? @"hidden or no room" : @"layout geometry changed"];
    self.hidden = !enabled || !room;
    if (self.hidden) return;
    _centers = centers;
    if (!_moving && !_touch) {
        _position = _defaultPosition;
        if (_compactColumn && centers.size.width > 0) {
            CGFloat offset = (_compactColumn - 1) * (outer + 4) / centers.size.width;
            _position.x = _defaultPosition.x == 0 ? offset : 1 - offset;
        }
        id saved = [defaults objectForKey:_positionKey];
        if ([saved isKindOfClass:NSArray.class] && [saved count] == 2 &&
            [saved[0] isKindOfClass:NSNumber.class] && [saved[1] isKindOfClass:NSNumber.class]) {
            double x = [saved[0] doubleValue], y = [saved[1] doubleValue];
            if (isfinite(x) && isfinite(y)) _position = CGPointMake(MAX(0, MIN(1, x)), MAX(0, MIN(1, y)));
        }
    }
    self.bounds = CGRectMake(0, 0, outer, outer);
    self.center = CGPointMake(centers.origin.x + centers.size.width * sp_touch_x(_position.x),
                             centers.origin.y + centers.size.height * _position.y);
    CGFloat face = outer - ring;
    _face.bounds = CGRectMake(0, 0, face, _handle ? MAX(32, face * 0.58) : face);
    _face.center = CGPointMake(outer / 2, outer / 2);
    _label.frame = CGRectInset(_face.bounds, 4, 0);
    _label.font = [UIFont systemFontOfSize:round(face * 0.27) weight:UIFontWeightSemibold];
    _handle.frame = self.bounds;
    _shield.frame = CGRectInset(self.bounds, -sp_joystick_touch_margin, -sp_joystick_touch_margin);
}
- (BOOL)containsKeyPoint:(CGPoint)point {
    if (!_handle) return CGRectContainsPoint(self.bounds, point);
    CGFloat r = self.bounds.size.width / 2;
    return hypot(point.x - r, point.y - r) <= r;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_handle) return [super pointInside:point withEvent:event];
    if ([self containsKeyPoint:point]) return YES;
    if (event && event.type != UIEventTypeTouches) return NO;
    for (UITouch *touch in event.allTouches) {
        CGPoint p = [touch locationInView:self];
        if (touch.phase == UITouchPhaseBegan && hypot(p.x - point.x, p.y - point.y) < 0.5 &&
            touch.type != UITouchTypeDirect) return NO;
    }
    CGFloat r = self.bounds.size.width / 2;
    return hypot(point.x - r, point.y - r) <= r + sp_joystick_touch_margin;
}
- (void)syncWithEvent:(UIEvent *)event {
    if (self.hidden) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.view != self) continue;
        NSSet *set = [NSSet setWithObject:touch];
        if (touch.phase == UITouchPhaseBegan) [self touchesBegan:set withEvent:event];
        else if (touch.phase == UITouchPhaseEnded) [self touchesEnded:set withEvent:event];
        else if (touch.phase == UITouchPhaseCancelled) [self touchesCancelled:set withEvent:event];
    }
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.hidden || _touch || _moving) return;
    for (UITouch *touch in touches) if ((touch.type == UITouchTypeDirect && !sp_physical_touch(touch)) || touch.type == UITouchTypePencil) {
        _touch = touch;
        _fingerStart = [touch locationInView:self.superview]; _centerStart = self.center;
        if (_editingPosition) {
            [self beginMove:touch];
            break;
        }
        if (_usage && !_keyDown) {
            sp_touch_key(_usage, YES);
            _keyDown = YES;
        }
        [self setHighlighted:YES];
        [_handle touchesBegan:[NSSet setWithObject:touch] withEvent:event];
        break;
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_touch || ![touches containsObject:_touch]) return;
    if (_editingPosition) { [self moveWithTouch:_touch]; return; }
    if (_handle) { [_handle touchesMoved:touches withEvent:event]; return; }
    if (_compactColumn || _action || _usage == 0x2B) return;
    CGPoint at = [_touch locationInView:self.superview];
    if (!_moving && hypot(at.x - _fingerStart.x, at.y - _fingerStart.y) < 10) return;
    _moving = YES;
    [self moveWithTouch:_touch];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) {
        [_handle touchesEnded:touches withEvent:event];
        [self touchesMoved:touches withEvent:event];
        BOOL activate = !_editingPosition && !_moving && [self containsKeyPoint:[_touch locationInView:self]];
        BOOL modifier = _usage >= 0xE0 && _usage <= 0xE2;
        if (activate && modifier && !_latched && _touch.tapCount == 2) _latched = YES;
        else [self releaseKeyWithReason:@"touch ended"];
        _touch = nil;
        [self endMove];
        [self flushDeferredLayout];
        if (activate && _action) _action();
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) [self cancelInputWithReason:@"touch cancelled"];
}
- (void)beginMove:(UITouch *)touch {
    [self releaseKeyWithReason:@"move ring unlocked"];
    _moving = YES;
    _fingerStart = [touch locationInView:self.superview]; _centerStart = self.center;
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
    if (CGPointEqualToPoint(self.center, _centerStart)) return;
    [NSUserDefaults.standardUserDefaults setObject:@[@(_position.x), @(_position.y)] forKey:_positionKey];
}
@end
