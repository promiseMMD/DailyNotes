import 'package:material_ui/material_ui.dart';

/// Preview-only styling. These are replaceable visual design candidates,
/// not new product requirements and not a real data source.
const previewCanvas = Color(0xFFF9F8F4);
const previewInk = Color(0xFF29372F);
const previewMuted = Color(0xFF788078);
const previewSage = Color(0xFF526E5B);
const previewLine = Color(0xFFE5E8E1);
const previewSoftSage = Color(0xFFE9EFE8);

class PreviewPageIntro extends StatelessWidget {
  const PreviewPageIntro({
    required this.kicker,
    required this.title,
    required this.subtitle,
    super.key,
  });

  final String kicker;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              kicker,
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.3,
                color: previewSage,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              title,
              style: const TextStyle(
                fontSize: 27,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: previewInk,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: previewMuted,
              ),
            ),
          ],
        ),
      );
}

class PreviewSectionHeader extends StatelessWidget {
  const PreviewSectionHeader({
    required this.title,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 17,
                decoration: BoxDecoration(
                  color: previewSage,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: previewInk,
                    fontSize: 16,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 5),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                subtitle!,
                style: const TextStyle(fontSize: 11, color: previewMuted),
              ),
            ),
          ],
        ],
      );
}

class PreviewEmptyState extends StatelessWidget {
  const PreviewEmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.compact = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 19 : 27),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: compact ? 38 : 44,
              height: compact ? 38 : 44,
              decoration: BoxDecoration(
                color: previewSoftSage,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: previewSage, size: compact ? 19 : 21),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: previewInk,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    description,
                    style: const TextStyle(
                      color: previewMuted,
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class PreviewThinDivider extends StatelessWidget {
  const PreviewThinDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      const Divider(color: previewLine, thickness: 1, height: 1);
}

class PreviewTabStrip extends StatelessWidget {
  const PreviewTabStrip({
    required this.labels,
    required this.activeIndex,
    required this.onSelect,
    super.key,
  });

  final List<String> labels;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(
            children: [
              for (var index = 0; index < labels.length; index++)
                Padding(
                  padding: const EdgeInsets.only(right: 25),
                  child: InkWell(
                    onTap: () => onSelect(index),
                    borderRadius: BorderRadius.circular(5),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 11),
                      child: Column(
                        children: [
                          Text(
                            labels[index],
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: index == activeIndex
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: index == activeIndex
                                  ? previewInk
                                  : previewMuted,
                            ),
                          ),
                          const SizedBox(height: 11),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            height: 3,
                            width: index == activeIndex ? 29 : 3,
                            decoration: BoxDecoration(
                              color: index == activeIndex
                                  ? previewSage
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const PreviewThinDivider(),
        ],
      );
}

class PreviewCreateGlyph extends StatelessWidget {
  const PreviewCreateGlyph({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: 32,
        width: 32,
        decoration: BoxDecoration(
          color: previewSage,
          borderRadius: BorderRadius.circular(11),
        ),
        child: const Icon(Icons.add, color: Colors.white, size: 22),
      );
}

class PreviewSoftTile extends StatelessWidget {
  const PreviewSoftTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 3),
        leading: Container(
          width: 39,
          height: 39,
          decoration: BoxDecoration(
            color: previewSoftSage,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: previewSage, size: 19),
        ),
        title: Text(title, style: const TextStyle(
          color: previewInk,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        )),
        subtitle: Text(subtitle, style: const TextStyle(
          color: previewMuted,
          fontSize: 11,
          height: 1.45,
        )),
        trailing: trailing,
        onTap: onTap,
      );
}
