(function () {
    var load = function load () {
        if (window.jQuery) {
            window.jQuery(document).ready(function () {
                init();
            });
        } else {
            setTimeout(load, 50);
        }
    };
    load();
    var init = function init () {
        setTimeout(function () { $('#save-success').fadeOut() }, 3000);
        setTimeout(function () { $('#already-processed').fadeOut() }, 3000);
        var $baskettype = $('#basket-type-selector input[name="basket-type"]');
        var basketinput = function () {
            var type = $('#basket-type-selector input[name="basket-type"]:checked').val();
            if (type === 'existing') {
                $('#order-basket-select').show();
                $('#order-basket-select select').attr('required', true);
            } else {
                $('#order-basket-select').hide();
                $('#order-basket-select select').removeAttr('required');
            }
            if (type === 'new-order') {
                $('#order-basket-order').show();
            } else {
                $('#order-basket-order').hide();
            }
            if (type === 'new') {
                $('#order-basket-name').show();
                $('#order-basket-name input').attr('required', true);
            } else {
                $('#order-basket-name').hide();
                $('#order-basket-name input').removeAttr('required');
            }
        };
        basketinput();
        $baskettype.change(basketinput);
    }
})();
