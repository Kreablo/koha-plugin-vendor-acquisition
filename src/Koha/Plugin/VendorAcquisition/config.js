(function () {
    var load = function load () {
        if (window.jQuery) {
            window.jQuery(document).ready(function () {
                init(window.jQuery);
            });
        } else {
            setTimeout(load, 50);
        }
    };
    load();
    var greatestid = function greatestid (prefix) {
        var max = 0;
        $('#vendor-mapping-container input').each(function (index, element) {
            var re = new RegExp(prefix + '(\\d+)');
            var matches = element.id.match(re);
            if (matches) {
                var n = Number(matches[1]);
                if (n > max) {
                    max = n;
                }
            }
        });
        return max;
    }

    var remove_mapping = function remove_mapping (event) {
        event.preventDefault();
        event.stopPropagation();
        var $e = $(event.currentTarget).parent().parent().remove();
    };

    var update_id = function update_id ($template, name, idn) {
            $template.find('[name="' + name + '"]').attr('id', name + '-' + idn);
            $template.find('[name="' + name + '"]').prev('label').attr('for', name + '-' + idn);
    }

    var init = function init ($) {
        setTimeout(function () { $('#save-success').fadeOut() }, 3000);

        $('#vendor-mapping-container button.remove-vendor-mapping').click(remove_mapping);
        $('#add-vendor-mapping').click(function (event) {
            event.preventDefault();
            event.stopPropagation();
            var idn = greatestid('vendor-id-') + 1;
            var $template = $('<div />').append($('#vendor-mapping-input-template').children().clone());
            update_id($template, 'vendor-id', idn);
            update_id($template, 'koha-vendor-id', idn);

            $template.find('button.remove-vendor-mapping').click(remove_mapping);
            $('#vendor-mapping-container').append($template);
        });

        $('#add-default-values button.remove-default-values').click(remove_mapping);
        $('#add-default-values').click(function (event) {
            event.preventDefault();
            event.stopPropagation();
            var idn = greatestid('customer-id-') + 1;
            var $template = $('<div />').append($('#default-values-template').children().clone());
            update_id($template, 'dustomer-id', idn);

            $template.find('button.remove-default-values').click(remove_mapping);
            $('#default-values-container').append($template);
        });
    }
})();
