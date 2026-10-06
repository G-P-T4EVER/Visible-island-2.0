#import "VIBlurHeaderCell.h"

@interface VIBlurHeaderCell ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
@end

@implementation VIBlurHeaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                  specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        UIBlurEffectStyle blurStyle;
        if (@available(iOS 13.0, *)) blurStyle = UIBlurEffectStyleSystemMaterial;
        else                         blurStyle = UIBlurEffectStyleLight;

        _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:blurStyle]];
        _blurView.clipsToBounds = YES;
        _blurView.layer.cornerRadius = 14.0;
        if (@available(iOS 13.0, *)) _blurView.layer.cornerCurve = kCACornerCurveContinuous;
        _blurView.userInteractionEnabled = NO;
        [self.contentView insertSubview:_blurView atIndex:0];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.blurView.frame = CGRectInset(self.contentView.bounds, 0.0, 3.0);
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return 56.0;
}

@end
