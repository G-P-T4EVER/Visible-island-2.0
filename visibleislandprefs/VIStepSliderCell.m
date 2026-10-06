#import "VIStepSliderCell.h"

@interface VIStepSliderCell ()
@property (nonatomic, strong) UILabel *valueLabel;
@end

@implementation VIStepSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                  specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        NSNumber *step = [specifier propertyForKey:@"step"];
        _step = step ? step.floatValue : 0.5f;

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        if (@available(iOS 13.0, *)) _valueLabel.textColor = UIColor.secondaryLabelColor;
        else                         _valueLabel.textColor = UIColor.grayColor;
        [self.contentView addSubview:_valueLabel];

        UISlider *slider = (UISlider *)self.control;
        slider.continuous = YES;
        [slider addTarget:self action:@selector(_sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self _updateLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    self.valueLabel.frame = CGRectMake(CGRectGetWidth(bounds) - 62.0, 0, 50.0, CGRectGetHeight(bounds));

    UISlider *slider = (UISlider *)self.control;
    CGRect frame = slider.frame;
    frame.size.width = MAX(80.0, CGRectGetWidth(frame) - 56.0);
    slider.frame = frame;
}

- (void)_sliderChanged:(UISlider *)slider {
    // Snap to the step grid, then feed the quantised value back so the stored
    // preference and the visible thumb position always agree.
    float snapped = roundf(slider.value / self.step) * self.step;
    if (fabsf(snapped - slider.value) > 0.0001f) slider.value = snapped;
    [self _updateLabel];
}

- (void)_updateLabel {
    UISlider *slider = (UISlider *)self.control;
    self.valueLabel.text = [NSString stringWithFormat:@"%+.1f", slider.value];
}

- (void)setValue:(id)value {
    [super setValue:value];
    [self _updateLabel];
}

// PSSliderTableCell reports the raw slider value; quantise on the way out too.
- (id)value {
    UISlider *slider = (UISlider *)self.control;
    return @(roundf(slider.value / self.step) * self.step);
}

@end
