import React from 'react';
import { Loader2 } from 'lucide-react';

export const PyramidLogo = ({ className = 'w-6 h-6' }) => (
  <svg viewBox="0 0 24 24" fill="currentColor" className={className}>
    <path d="M12 2L2 22h20L12 2z" />
    <path d="M12 8L6 18h12L12 8z" opacity="0.6" />
  </svg>
);

export const Button = ({
  children,
  variant = 'primary',
  loading = false,
  disabled,
  onClick,
  className = '',
  ...props
}) => {
  const variants = {
    primary: 'bg-yellow-500 hover:bg-yellow-400 text-black',
    success: 'bg-green-500 hover:bg-green-600 text-white',
    danger: 'bg-red-500 hover:bg-red-600 text-white',
    ghost: 'bg-white/5 hover:bg-white/10 text-gray-400',
  };

  return (
    <button
      onClick={onClick}
      disabled={disabled || loading}
      className={`px-6 py-3 rounded-lg font-bold transition-all disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2 ${variants[variant]} ${className}`}
      {...props}
    >
      {loading && <Loader2 className="w-4 h-4 animate-spin" />}
      {children}
    </button>
  );
};

export const Card = ({ children, className = '' }) => (
  <div className={`bg-white/5 border border-yellow-500/20 rounded-xl p-6 ${className}`}>
    {children}
  </div>
);

export const Input = ({
  label,
  value,
  onChange,
  type = 'text',
  placeholder,
  disabled,
  helperText,
  ...props
}) => (
  <div>
    {label && <label className="text-sm text-gray-400 mb-2 block">{label}</label>}
    <input
      type={type}
      value={value}
      onChange={onChange}
      placeholder={placeholder}
      disabled={disabled}
      className="w-full bg-black border border-yellow-500/30 rounded-lg px-4 py-3 text-white focus:outline-none focus:border-yellow-500 disabled:opacity-50"
      {...props}
    />
    {helperText && <div className="text-xs text-gray-400 mt-1">{helperText}</div>}
  </div>
);
